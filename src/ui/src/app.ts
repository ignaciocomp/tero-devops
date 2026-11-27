import express from 'express';
import type { IncomingMessage } from 'http';
import path from 'path';
import { createProxyMiddleware, type Plugin } from 'http-proxy-middleware';
import { createLogger, logProcessEvents, requestLogger } from './logger';

const logger = createLogger('ui');
logProcessEvents(logger);

// Errores del proxy (por ejemplo, un backend que no responde) en JSON, con un msg fijo y solo
// la ruta. No se usa la opción logger de http-proxy-middleware porque su mensaje de error trae
// el Host y la URL con la query string. Este plugin solo agrega un listener: el que responde
// 502/504 sigue activo.
const proxyErrors: Plugin = (proxyServer) => {
  proxyServer.on('error', (err: Error, req: IncomingMessage) => {
    const url = (req as IncomingMessage & { originalUrl?: string }).originalUrl ?? req.url ?? '';
    logger.error('proxy error', {
      component: 'proxy',
      method: req.method,
      path: url.split('?')[0],
      error: (err as NodeJS.ErrnoException).code ?? err.name,
    });
  });
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

app.use('/api/catalog',  createProxyMiddleware({ target: CATALOG_URL,  changeOrigin: true, pathRewrite: rewrite('/catalog'),  plugins: [proxyErrors] }));
app.use('/api/carts',    createProxyMiddleware({ target: CARTS_URL,    changeOrigin: true, pathRewrite: rewrite('/carts'),    plugins: [proxyErrors] }));
app.use('/api/checkout', createProxyMiddleware({ target: CHECKOUT_URL, changeOrigin: true, pathRewrite: rewrite('/checkout'), plugins: [proxyErrors] }));
app.use('/api/orders',   createProxyMiddleware({ target: ORDERS_URL,   changeOrigin: true, pathRewrite: rewrite('/orders'),   plugins: [proxyErrors] }));

app.use(express.static(path.join(__dirname, '../public')));

app.get('/health', (_req, res) => res.send('OK'));

const port = parseInt(process.env.PORT || '8080', 10);
app.listen(port, () => logger.info('listening', { port }));
