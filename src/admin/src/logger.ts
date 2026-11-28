import type { Request, Response, NextFunction, ErrorRequestHandler } from 'express';
import { format } from 'util';

// Logs en JSON, una línea por evento, con los mismos campos en los seis servicios:
// time (UTC), level (info, warn, error), service y msg. Los requests suman method,
// path, status y duration_ms. Así CloudWatch Logs Insights filtra por campo.
type Level = 'info' | 'warn' | 'error';
type Fields = Record<string, unknown>;

export interface Logger {
  info(msg: string, fields?: Fields): void;
  warn(msg: string, fields?: Fields): void;
  error(msg: string, fields?: Fields): void;
}

export function createLogger(service: string): Logger {
  const write = (level: Level, msg: string, fields: Fields = {}): void => {
    const line = JSON.stringify({ time: new Date().toISOString(), level, service, msg, ...fields });
    process.stdout.write(line + '\n');
  };
  return {
    info: (msg, fields) => write('info', msg, fields),
    warn: (msg, fields) => write('warn', msg, fields),
    error: (msg, fields) => write('error', msg, fields),
  };
}

// Un log por request al terminar la respuesta. Solo la ruta, sin la query string, para no
// dejar datos de los usuarios. Las rutas de skip (el health check) no se registran: en la
// nube las consulta el balanceador cada pocos segundos.
export function requestLogger(logger: Logger, skip: string[] = []) {
  return (req: Request, res: Response, next: NextFunction): void => {
    const start = process.hrtime.bigint();
    res.on('finish', () => {
      const path = req.originalUrl.split('?')[0];
      if (skip.includes(path)) return;
      const status = res.statusCode;
      const level: Level = status >= 500 ? 'error' : status >= 400 ? 'warn' : 'info';
      const durationMs = Number(process.hrtime.bigint() - start) / 1e6;
      logger[level]('request', {
        method: req.method,
        path,
        status,
        duration_ms: Math.round(durationMs * 1000) / 1000,
      });
    });
    next();
  };
}

// Manejador de errores, al final de la cadena. Sin él, Express escribe el stack en texto por
// stderr: con un body que no es JSON o es muy grande, una ruta mal codificada o un Range que
// no se puede servir. Además, el mensaje de JSON.parse trae un pedazo del body, que en el
// login de admin puede ser la contraseña. El requestLogger ya registra el request con su
// status, así que acá solo se agrega el detalle de los 5xx. Al cliente le llega solo el texto
// del status, como con Express en producción, nunca err.message.
export function errorHandler(logger: Logger): ErrorRequestHandler {
  return (err: unknown, req: Request, res: Response, _next: NextFunction): void => {
    const { status, statusCode, stack } = (err ?? {}) as { status?: unknown; statusCode?: unknown; stack?: unknown };
    const code = Number(status ?? statusCode);
    const httpStatus = code >= 400 && code < 600 ? code : 500;
    if (httpStatus >= 500) {
      logger.error('unhandled error', {
        path: req.originalUrl.split('?')[0],
        error: typeof stack === 'string' ? stack : String(err),
      });
    }
    if (res.headersSent) {
      req.socket.destroy();
      return;
    }
    res.sendStatus(httpStatus);
  };
}

// Los avisos de Node (por ejemplo, APIs deprecadas que usa alguna dependencia) y los errores
// que tiran abajo el proceso también salen en JSON. Ante un error, el proceso termina igual
// que antes (código 1), y compose o ECS lo vuelven a levantar.
export function logProcessEvents(logger: Logger): void {
  // Node escribe los avisos en texto con su propio listener: se reemplaza por uno en JSON.
  process.removeAllListeners('warning');
  process.on('warning', (warning) => {
    logger.warn(warning.message, { warning: warning.name, code: (warning as { code?: string }).code });
  });
  process.on('uncaughtException', (err) => {
    logger.error('uncaught exception', { error: err.stack ?? String(err) });
    process.exit(1);
  });
  process.on('unhandledRejection', (reason) => {
    logger.error('unhandled rejection', {
      error: reason instanceof Error ? reason.stack ?? reason.message : format(reason),
    });
    process.exit(1);
  });
}
