// Teste de carga do bônus (HPA): 80 VUs por 3 minutos batendo em /api/messages
// através do Ingress. Acompanhe o escalonamento em outro terminal com:
//   kubectl get hpa -n mural -w
import http from 'k6/http';

export const options = {
  vus: 80,
  duration: '3m',
};

export default function () {
  http.get(`http://${__ENV.INGRESS_HOST || 'mural.localtest.me'}/api/messages`);
}
