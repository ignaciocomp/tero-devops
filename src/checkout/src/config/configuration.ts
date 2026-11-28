export default () => ({
  persistence: {
    provider: process.env.RETAIL_CHECKOUT_PERSISTENCE_PROVIDER || 'in-memory',
    redis: {
      url: process.env.RETAIL_CHECKOUT_PERSISTENCE_REDIS_URL || '',
      // Va aparte de la URL: en ECS llega como un secreto de Secrets Manager, y la URL queda
      // sin la clave. Vale para el cliente de escritura y para el de lectura.
      password: process.env.RETAIL_CHECKOUT_PERSISTENCE_REDIS_PASSWORD || '',
      reader: {
        url: process.env.RETAIL_CHECKOUT_PERSISTENCE_REDIS_READER_URL || '',
      },
    },
  },
  endpoints: {
    orders: process.env.RETAIL_CHECKOUT_ENDPOINTS_ORDERS || '',
  },
  shipping: {
    prefix: process.env.RETAIL_CHECKOUT_SHIPPING_NAME_PREFIX || '',
  },
});
