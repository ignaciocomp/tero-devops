import { Injectable, Logger, NestMiddleware } from '@nestjs/common';
import { Request, Response, NextFunction } from 'express';

// Un log por request al terminar la respuesta, con campos (ver json-logger.ts). Solo la
// ruta, sin la query string, ni IP ni user agent, para no dejar datos de los usuarios.
// El health check no se registra: en la nube lo consulta el balanceador cada pocos segundos.
@Injectable()
export class LoggerMiddleware implements NestMiddleware {
  private logger = new Logger(`HTTP`);
  use(request: Request, response: Response, next: NextFunction) {
    const startAt = process.hrtime.bigint();
    const { method, originalUrl } = request;
    const path = originalUrl.split('?')[0];

    response.on('finish', () => {
      if (path === '/health') return;
      const { statusCode } = response;
      const durationMs = Number(process.hrtime.bigint() - startAt) / 1e6;
      const entry = {
        msg: 'request',
        method,
        path,
        status: statusCode,
        duration_ms: Math.round(durationMs * 1000) / 1000,
      };
      if (statusCode >= 500) {
        this.logger.error(entry);
      } else if (statusCode >= 400) {
        this.logger.warn(entry);
      } else {
        this.logger.log(entry);
      }
    });

    next();
  }
}
