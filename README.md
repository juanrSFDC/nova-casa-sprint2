# Nova Casa · Sprint 2 · Monitoreo de equipos con Salesforce

Nova Casa vigila con sensores los equipos de sus edificios: bombas, salas técnicas, medidores de agua y de energía, y cámaras. Esta solución recibe sus señales en Salesforce y hace lo siguiente:

- descarta las repetidas, las imposibles y las atrasadas;
- clasifica cada lectura como normal, advertencia o crítica según los límites que define Nova Casa;
- abre una sola intervención por mensaje crítico;
- avisa a quien debe atenderla;
- deja registrado qué pasó con cada mensaje.

Equipo: Juan Enrique Rozo y Juan Flórez.

## Documentación

La documentación de la entrega va en `docs/entrega/pdf/`:

| Documento | Contenido |
|---|---|
| `documentacion-nova-casa.pdf` | Documento completo, con las cinco partes |
| `01-documentacion-tecnica.pdf` | Componentes, secciones clave del código, pruebas y despliegue |
| `02-documentacion-funcional.pdf` | Requerimientos, reglas de negocio, manual por rol y extras |
| `03-arquitectura-diseno.pdf` | Arquitectura, flujos y decisiones de diseño |
| `04-modelo-de-datos.pdf` | Objetos, campos, relaciones y claves |
| `05-permisos-acceso-org.pdf` | Usuarios, perfiles, permission sets y compartición |

## Estructura

```text
salesforce/
  sfdx-project.json        Proyecto SFDX (API 67.0, paquete force-app)
  manifest/package.xml     Manifiesto de la solución
  force-app/main/default/  Metadata y código: Apex, triggers, LWC, objetos, flows, permisos…
  package.json, jest.config.js, jest-mocks/   Configuración de las pruebas Jest de los LWC
herramientas/
  sensor_portatil.py       Segunda fuente real de señales: publica por la API REST
```

## Pruebas

- **Apex:** se ejecutan contra una org con la solución desplegada.

  ```bash
  cd salesforce
  sf apex run test --test-level RunLocalTests --code-coverage --result-format human --target-org <alias>
  ```

  Al cierre del sprint, las clases de prueba del proyecto suman 609 pruebas en verde, con 96 % de cobertura en las clases del proyecto.

- **LWC (Jest):** se ejecutan en local.

  ```bash
  cd salesforce
  npm install
  npm run test:unit
  ```

## Despliegue

El despliegue se hace por componentes o con el manifiesto (`salesforce/manifest/package.xml`). Después hay que completar la configuración que no viaja en la metadata. El detalle está en el capítulo «Despliegue y configuración» de la documentación técnica:

- el token del simulador, en la External Credential;
- la URL del webhook de Slack, en la Named Credential `Slack_Nova_Casa`, puesta en Configuración;
- el usuario de integración del suscriptor del evento;
- la asignación de permission sets;
- los ajustes personalizados;
- los datos de referencia: edificios, activos y umbrales.

En una org donde la URL real del webhook ya está puesta, no vuelvas a desplegar `Slack_Nova_Casa`: el archivo del repositorio tiene una URL de ejemplo y la reemplazaría.

## Seguridad

El repositorio no contiene secretos:

- el token del simulador vive en la External Credential de la org;
- la URL del webhook de Slack vive en la Named Credential de la org;
- no hay contraseñas.

Las credenciales de acceso a la org de demostración se entregan por un canal privado.
