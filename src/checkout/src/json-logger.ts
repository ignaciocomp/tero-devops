import { LoggerService } from '@nestjs/common';

// Logs en JSON, una línea por evento, con los mismos campos en los seis servicios:
// time (UTC), level (info, warn, error), service y msg. Los requests suman method,
// path, status y duration_ms. Así CloudWatch Logs Insights filtra por campo.
// Reemplaza al ConsoleLogger de Nest, así también los mensajes del framework (arranque,
// rutas, errores no manejados) salen en JSON.
type Level = 'debug' | 'info' | 'warn' | 'error';

export class JsonLogger implements LoggerService {
  constructor(private readonly service: string) {}

  log(message: unknown, ...params: unknown[]): void {
    this.write('info', message, params);
  }

  error(message: unknown, ...params: unknown[]): void {
    this.write('error', message, params);
  }

  warn(message: unknown, ...params: unknown[]): void {
    this.write('warn', message, params);
  }

  debug(message: unknown, ...params: unknown[]): void {
    this.write('debug', message, params);
  }

  verbose(message: unknown, ...params: unknown[]): void {
    this.write('debug', message, params);
  }

  fatal(message: unknown, ...params: unknown[]): void {
    this.write('error', message, params);
  }

  private write(level: Level, message: unknown, params: unknown[]): void {
    const fields: Record<string, unknown> = {};
    const rest = [...params];
    // Nest pasa el contexto (el nombre de la clase) como último parámetro, y en los errores
    // el stack antes del contexto. Si el error no trae stack, Nest deja undefined en ese
    // lugar: se descarta, para no registrar "details":[null].
    if (rest.length > 0 && typeof rest[rest.length - 1] === 'string') {
      fields.context = rest.pop();
    }
    if (level === 'error' && rest.length > 0 && (typeof rest[0] === 'string' || rest[0] === undefined)) {
      const stack = rest.shift();
      if (stack !== undefined) fields.error = stack;
    }

    let msg: string;
    if (message instanceof Error) {
      msg = message.message;
      fields.error = errorText(message);
    } else if (message !== null && typeof message === 'object') {
      // Un objeto se registra como campos: { msg, method, path, ... }
      const { msg: text, ...others } = message as Record<string, unknown>;
      msg = String(text ?? '');
      Object.assign(fields, others);
    } else {
      msg = String(message);
    }
    if (rest.length > 0) {
      fields.details = rest.map((r) => (r instanceof Error ? errorText(r) : r));
    }

    const line = JSON.stringify({
      time: new Date().toISOString(),
      level,
      service: this.service,
      msg,
      ...fields,
    });
    process.stdout.write(line + '\n');
  }
}

// Texto de un error para el campo "error": el stack más la cadena de causas. El stack no
// incluye err.cause, y ahí suele estar el motivo real: el "fetch failed" de undici trae el
// ECONNREFUSED o el EAI_AGAIN solo en la causa. De cada causa van el nombre, el mensaje y el
// código. No se usa util.inspect porque ioredis guarda en sus errores los argumentos del
// comando.
export function errorText(error: unknown): string {
  if (!(error instanceof Error)) return String(error);
  let text = error.stack ?? `${error.name}: ${error.message}`;
  let cause = (error as { cause?: unknown }).cause;
  for (let i = 0; i < 5 && cause !== undefined && cause !== null; i++) {
    if (!(cause instanceof Error)) {
      text += `\n[cause] ${String(cause)}`;
      break;
    }
    const code = (cause as { code?: unknown }).code;
    text += `\n[cause] ${cause.name}: ${cause.message}${code === undefined ? '' : ` (${String(code)})`}`;
    cause = (cause as { cause?: unknown }).cause;
  }
  return text;
}
