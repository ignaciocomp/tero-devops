import { Controller, Get } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

@Controller()
export class AppController {
  constructor(private configService: ConfigService) {}

  @Get('health')
  health() {
    return { status: 'ok' };
  }

  // Solo el tipo de persistencia: la URL de Redis puede llevar la contraseña, y el endpoint es
  // un detalle de la infraestructura que no hace falta exponer.
  @Get('topology')
  topology() {
    return { persistenceProvider: this.configService.get('persistence.provider') };
  }
}
