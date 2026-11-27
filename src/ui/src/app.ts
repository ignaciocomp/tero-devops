import express from 'express';
import path from 'path';
import { format } from 'util';
import { createProxyMiddleware } from 'http-proxy-middleware';
import { createLogger, logProcessEvents, requestLogger } from './logger';

const logger = createLogger('ui');
logProcessEvents(logger);

// http-proxy-middleware avisa con este logger, por ejemplo cuando un backend no responde.
const proxyLogger = {
  info: () => {},
  warn: (...args: unknown[]) => logger.warn(format(...args), { component: 'proxy' }),
  error: (...args: unknown[]) => logger.error(format(...args), { component: 'proxy' }),
};

const app = express();
app.use(requestLogger(logger, ['/health']));

const CATALOG_URL  = process.env.RETAIL_UI_ENDPOINTS_CATALOG  || 'http://catalog:8080';
const CARTS_URL    = process.env.RETAIL_UI_ENDPOINTS_CARTS    || 'http://carts:8080';
const CHECKOUT_URL = process.env.RETAIL_UI_ENDPOINTS_CHECKOUT || 'http://checkout:8080';
const ORDERS_URL   = process.env.RETAIL_UI_ENDPOINTS_ORDERS   || 'http://orders:8080';

// Express strips the mount path before the proxy sees it.
// pathRewrite re-adds the service prefix, stripping trailing slash on bare paths.
const rewrite = (prefix: string) => (p: string) => prefix + (p === '/' ? '' : p);

app.use('/api/catalog',  createProxyMiddleware({ target: CATALOG_URL,  changeOrigin: true, pathRewrite: rewrite('/catalog'),  logger: proxyLogger }));
app.use('/api/carts',    createProxyMiddleware({ target: CARTS_URL,    changeOrigin: true, pathRewrite: rewrite('/carts'),    logger: proxyLogger }));
app.use('/api/checkout', createProxyMiddleware({ target: CHECKOUT_URL, changeOrigin: true, pathRewrite: rewrite('/checkout'), logger: proxyLogger }));
app.use('/api/orders',   createProxyMiddleware({ target: ORDERS_URL,   changeOrigin: true, pathRewrite: rewrite('/orders'),   logger: proxyLogger }));

app.use(express.static(path.join(__dirname, '../public')));

app.get('/health', (_req, res) => res.send('OK'));

const port = parseInt(process.env.PORT || '8080', 10);
app.listen(port, () => logger.info('listening', { port }));
