import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import jwt from 'jsonwebtoken';
import { Pool } from 'pg';
import crypto from 'crypto';
import path from 'path';
import { createLogger, logProcessEvents, requestLogger } from './logger';

const logger = createLogger('admin');
logProcessEvents(logger);

const app = express();
app.use(requestLogger(logger, ['/health']));
app.use(express.json());
app.use(cookieParser());

// Los secretos no tienen valor por defecto: si falta alguno, el servicio no arranca.
function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    logger.error('Falta la variable de entorno obligatoria', { variable: name });
    process.exit(1);
  }
  return value;
}

const JWT_SECRET   = requireEnv('ADMIN_JWT_SECRET');
const ADMIN_USER   = process.env.ADMIN_USERNAME      || 'admin';
const ADMIN_PASS   = requireEnv('ADMIN_PASSWORD');
const DB_HOST      = process.env.DB_HOST             || 'db';
const DB_PORT      = parseInt(process.env.DB_PORT    || '5432');
const DB_USER      = process.env.DB_USER             || 'retail_user';
const DB_PASS      = requireEnv('DB_PASSWORD');

// TLS hacia la base, con los mismos valores que en los otros servicios: RDS con PostgreSQL 16
// rechaza las conexiones sin TLS. require cifra sin verificar el certificado, igual que en
// libpq. verify-full además lo verifica contra las CA que trae Node.
function dbSsl(mode: string): false | { rejectUnauthorized: boolean } {
  switch (mode) {
    case 'disable':     return false;
    // Riesgo aceptado (ADR 0004): require cifra sin verificar el certificado, igual que en libpq.
    // nosemgrep: problem-based-packs.insecure-transport.js-node.bypass-tls-verification.bypass-tls-verification
    case 'require':     return { rejectUnauthorized: false };
    case 'verify-full': return { rejectUnauthorized: true };
    default:
      logger.error('unsupported DB_SSLMODE', { value: mode, supported: 'disable, require, verify-full' });
      process.exit(1);
  }
}
const DB_SSL = dbSsl(process.env.DB_SSLMODE || 'require');

// application_name: para ver en pg_stat_activity qué servicio tiene cada conexión.
// connectionTimeoutMillis: si la base no responde, la consulta falla a los 5 s, como en los otros
// servicios, en lugar de esperar lo que tarde TCP.
const dbConfig = {
  host: DB_HOST, port: DB_PORT, user: DB_USER, password: DB_PASS, ssl: DB_SSL,
  application_name: 'admin', connectionTimeoutMillis: 5000,
};
const catalogDb = new Pool({ ...dbConfig, database: 'catalogdb' });
const ordersDb  = new Pool({ ...dbConfig, database: 'orders' });
// Si la base corta una conexión inactiva (un reinicio o un failover de RDS), el Pool emite
// 'error'. Sin listener, Node lo toma como una excepción no manejada y el proceso se cae. pg ya
// saca esa conexión del Pool y abre otra cuando haga falta: alcanza con registrarlo, como warn,
// porque se recupera solo.
for (const [database, pool] of [['catalogdb', catalogDb], ['orders', ordersDb]] as const) {
  pool.on('error', (err) => {
    logger.warn('idle database connection lost', { database, error: err.message });
  });
}

// Express 4 no espera las promesas de los handlers: si una consulta falla (por ejemplo, con la
// base caída), el rechazo queda sin manejar y logProcessEvents termina el proceso. handle()
// registra el error en el log y responde 500, y el proceso sigue.
function handle(fn: (req: Request, res: Response) => Promise<void>) {
  return (req: Request, res: Response): void => {
    fn(req, res).catch((err: unknown) => {
      logger.error('request failed', {
        method: req.method,
        path: req.path,
        error: err instanceof Error ? err.stack ?? err.message : String(err),
      });
      if (!res.headersSent) res.status(500).json({ error: 'Internal Server Error' });
    });
  };
}

// ── Auth middleware ────────────────────────────────────────────────────────

function requireAuth(req: Request, res: Response, next: NextFunction): void {
  const token = req.cookies?.token as string | undefined;
  if (!token) { res.status(401).json({ error: 'Unauthorized' }); return; }
  try {
    jwt.verify(token, JWT_SECRET);
    next();
  } catch {
    res.status(401).json({ error: 'Invalid token' });
  }
}

// ── Auth routes ────────────────────────────────────────────────────────────

app.post('/auth/login', (req: Request, res: Response): void => {
  const { username = '', password = '' } = req.body as { username?: string; password?: string };

  // Pad buffers to same length before timing-safe compare to avoid length leak
  const pad = (a: Buffer, b: Buffer): [Buffer, Buffer] => {
    const len = Math.max(a.length, b.length);
    return [Buffer.concat([a, Buffer.alloc(len - a.length)]),
            Buffer.concat([b, Buffer.alloc(len - b.length)])];
  };

  const [u1, u2] = pad(Buffer.from(username), Buffer.from(ADMIN_USER));
  const [p1, p2] = pad(Buffer.from(password), Buffer.from(ADMIN_PASS));

  const userOk = crypto.timingSafeEqual(u1, u2) && username.length === ADMIN_USER.length;
  const passOk = crypto.timingSafeEqual(p1, p2) && password.length === ADMIN_PASS.length;

  if (!userOk || !passOk) {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }

  const token = jwt.sign({ username }, JWT_SECRET, { expiresIn: '8h' });
  res.cookie('token', token, {
    httpOnly: true,
    sameSite: 'strict',
    maxAge: 8 * 3600 * 1000,
  });
  res.json({ ok: true });
});

app.post('/auth/logout', (_req: Request, res: Response): void => {
  res.clearCookie('token');
  res.json({ ok: true });
});

app.get('/auth/me', requireAuth, (_req: Request, res: Response): void => {
  res.json({ ok: true });
});

// ── Products CRUD ──────────────────────────────────────────────────────────

app.get('/admin/api/products', requireAuth, handle(async (_req: Request, res: Response): Promise<void> => {
  const { rows } = await catalogDb.query(`
    SELECT p.id, p.name, p.description, p.price,
           COALESCE(array_agg(pt.tag_name) FILTER (WHERE pt.tag_name IS NOT NULL), '{}') AS tags
    FROM products p
    LEFT JOIN product_tags pt ON p.id = pt.product_id
    GROUP BY p.id
    ORDER BY p.name
  `);
  res.json(rows);
}));

app.post('/admin/api/products', requireAuth, handle(async (req: Request, res: Response): Promise<void> => {
  const { name, description, price } = req.body as { name?: string; description?: string; price?: number };
  if (!name || price === undefined) { res.status(400).json({ error: 'name and price are required' }); return; }
  const id = crypto.randomUUID().replace(/-/g, '').slice(0, 26).toUpperCase();
  await catalogDb.query(
    'INSERT INTO products (id, name, description, price) VALUES ($1, $2, $3, $4)',
    [id, name.trim(), (description || '').trim(), price],
  );
  res.status(201).json({ id, name, description, price });
}));

app.put('/admin/api/products/:id', requireAuth, handle(async (req: Request, res: Response): Promise<void> => {
  const { name, description, price } = req.body as { name?: string; description?: string; price?: number };
  if (!name || price === undefined) { res.status(400).json({ error: 'name and price are required' }); return; }
  const { rowCount } = await catalogDb.query(
    'UPDATE products SET name=$1, description=$2, price=$3 WHERE id=$4',
    [name.trim(), (description || '').trim(), price, req.params.id],
  );
  if (!rowCount) { res.status(404).json({ error: 'Product not found' }); return; }
  res.json({ ok: true });
}));

app.delete('/admin/api/products/:id', requireAuth, handle(async (req: Request, res: Response): Promise<void> => {
  await catalogDb.query('DELETE FROM product_tags WHERE product_id = $1', [req.params.id]);
  await catalogDb.query('DELETE FROM products WHERE id = $1', [req.params.id]);
  res.json({ ok: true });
}));

// ── Orders (read-only) ─────────────────────────────────────────────────────

app.get('/admin/api/orders', requireAuth, handle(async (_req: Request, res: Response): Promise<void> => {
  const { rows } = await ordersDb.query(`
    SELECT o.id, o.created_at, o.first_name, o.last_name, o.email,
           o.address1, o.city, o.state, o.zip_code,
           COALESCE(
             json_agg(
               json_build_object(
                 'productId', oi.product_id,
                 'name',      oi.name,
                 'quantity',  oi.quantity,
                 'unitCost',  oi.unit_cost,
                 'totalCost', oi.total_cost
               )
             ) FILTER (WHERE oi.id IS NOT NULL), '[]'
           ) AS items
    FROM orders o
    LEFT JOIN order_items oi ON o.id = oi.order_id
    GROUP BY o.id
    ORDER BY o.created_at DESC
  `);
  res.json(rows);
}));

// ── Static + health ────────────────────────────────────────────────────────

app.get('/health', (_req: Request, res: Response): void => { res.send('OK'); });

app.use(express.static(path.join(__dirname, '../public')));
app.get('*', (_req: Request, res: Response): void => {
  res.sendFile(path.join(__dirname, '../public/index.html'));
});

const port = parseInt(process.env.PORT || '8080');
app.listen(port, () => logger.info('listening', { port }));
