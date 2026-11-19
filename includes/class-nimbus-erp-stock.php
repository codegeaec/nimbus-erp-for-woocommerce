<?php
if (!defined('ABSPATH')) {
	exit;
}

/**
 * Stock de la tienda → ERP, solo para cambios hechos a mano en WooCommerce (editar el producto, importar un
 * CSV…). No se envían:
 * - los descuentos/devoluciones de stock por pedidos: el ERP ya los descuenta al recibir el pedido (si no, se
 *   descontaría dos veces);
 * - los cambios que hace el propio ERP por la API REST (header X-Nimbus-Erp): volverían al ERP sin cambios.
 *
 * Se manda la diferencia (de 5 a 8 es +3), no el valor: el ERP la suma a su propio stock, así una venta que hizo el
 * ERP y que la tienda todavía no recibió no se pisa. Cada cambio lleva un `change_id` propio que se repite en los
 * reintentos (1, 5, 15, 60 y 180 minutos si el ERP no lo acepta): el ERP reconoce un cambio ya aplicado y no lo
 * suma dos veces.
 */
final class Nimbus_ERP_Stock {
	const ACTION = 'nimbus_erp_send_stock';
	const GROUP = 'nimbus-erp-for-woocommerce';
	const RETRY_MINUTES = array(1, 5, 15, 60, 180);

	/** true mientras WooCommerce descuenta o repone stock por un pedido. */
	private static $order_stock_change = false;

	/** Stock guardado antes del cambio en curso, por id de producto o variación. */
	private static $previous = array();

	public static function init() {
		add_filter('woocommerce_can_reduce_order_stock', array(__CLASS__, 'order_change_start'), 999);
		add_filter('woocommerce_can_restore_order_stock', array(__CLASS__, 'order_change_start'), 999);
		add_action('woocommerce_reduce_order_stock', array(__CLASS__, 'order_change_end'));
		add_action('woocommerce_restore_order_stock', array(__CLASS__, 'order_change_end'));

		add_action('woocommerce_product_before_set_stock', array(__CLASS__, 'before_stock_set'));
		add_action('woocommerce_variation_before_set_stock', array(__CLASS__, 'before_stock_set'));
		add_action('woocommerce_product_set_stock', array(__CLASS__, 'on_stock_set'));
		add_action('woocommerce_variation_set_stock', array(__CLASS__, 'on_stock_set'));
		add_action(self::ACTION, array(__CLASS__, 'send'), 10, 5);
	}

	public static function order_change_start($can) {
		if ($can) {
			self::$order_stock_change = true;
		}
		return $can;
	}

	public static function order_change_end() {
		self::$order_stock_change = false;
	}

	private static function comes_from_erp() {
		return defined('REST_REQUEST') && REST_REQUEST && (!empty($_SERVER['HTTP_X_NIMBUS_ERP']) || !empty($_SERVER['HTTP_X_CODEGEA_ERP']));
	}

	private static function watching() {
		return Nimbus_ERP_Settings::get('stock_to_erp') === 'yes' && !self::$order_stock_change && !self::comes_from_erp();
	}

	/**
	 * WooCommerce avisa antes de escribir el stock nuevo: lo guardado todavía es el valor anterior. Sin valor (el
	 * producto empieza a manejar stock) cuenta como 0.
	 *
	 * @param WC_Product $product
	 */
	public static function before_stock_set($product) {
		if (self::watching()) {
			self::$previous[$product->get_id()] = (float) get_post_meta($product->get_id(), '_stock', true);
		}
	}

	/** @param WC_Product $product */
	public static function on_stock_set($product) {
		$id = $product->get_id();
		if (!self::watching() || !array_key_exists($id, self::$previous)) {
			return;
		}
		$delta = (float) $product->get_stock_quantity() - self::$previous[$id];
		unset(self::$previous[$id]);
		if (!$product->get_sku() || !$product->managing_stock() || abs($delta) < 0.0001) {
			return;
		}
		self::enqueue(array(
			'product_id' => (int) $id,
			'sku' => (string) $product->get_sku(),
			'delta' => $delta,
			'change_id' => wp_generate_uuid4(),
			'attempt' => 0,
		), 0);
	}

	/** El orden de `$args` es el de los parámetros de send(): Action Scheduler los pasa por posición. */
	private static function enqueue(array $args, $delay_seconds) {
		if (function_exists('as_schedule_single_action')) {
			as_schedule_single_action(time() + $delay_seconds, self::ACTION, $args, self::GROUP);
		} else {
			self::send($args['product_id'], $args['sku'], $args['delta'], $args['change_id'], $args['attempt']);
		}
	}

	public static function send($product_id, $sku = null, $delta = null, $change_id = null, $attempt = 0) {
		// Envíos encolados por la versión 1.2.x (solo el id, para mandar el valor): ese formato ya no se usa.
		if ($sku === null || $change_id === null || !Nimbus_ERP_Settings::is_configured()) {
			return;
		}
		$delta = (float) $delta;
		$data = array(
			'items' => array(array('sku' => (string) $sku, 'delta' => $delta, 'change_id' => (string) $change_id)),
			'warehouse_id' => (int) Nimbus_ERP_Settings::get('warehouse_id') ?: null,
		);
		$result = Nimbus_ERP_Client::post('stock', $data);
		$label = ($delta > 0 ? '+' : '') . wc_stock_amount($delta);
		if ($result['ok']) {
			$skipped = is_array($result['body']) && in_array((string) $sku, (array) ($result['body']['skipped'] ?? array()), true);
			Nimbus_ERP_Log::add('stock', $sku, !$skipped, $skipped ? 'El ERP no tiene un producto con este SKU: cambio ' . $label . ' no aplicado.' : 'Stock ' . $label);
			return;
		}
		$attempt = (int) $attempt;
		Nimbus_ERP_Log::add('stock', $sku, false, $label . ': ' . $result['error']);
		if ($attempt < count(self::RETRY_MINUTES)) {
			self::enqueue(array(
				'product_id' => (int) $product_id,
				'sku' => (string) $sku,
				'delta' => $delta,
				'change_id' => (string) $change_id,
				'attempt' => $attempt + 1,
			), self::RETRY_MINUTES[$attempt] * MINUTE_IN_SECONDS);
		}
	}
}
