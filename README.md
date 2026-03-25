# PROJETO INTEGRADOR IFRN-PAR
Insttalçao do Graylog com apenas um comando no debian 13 - projeto integrador IFRN


🚀 Como executar com um só comando
Para facilitar, você pode rodar isto diretamente do seu terminal (assumindo que você baixou o arquivo ou vai usar um curl para um repositório seu):

Dê permissão de execução: chmod +x install_graylog.sh

Execute: sudo ./install_graylog.sh

⚠️ Arquitetura: O Graylog funciona como um agregador. Certifique-se de que as portas 9000 (Web/API) e as portas de entrada de logs (ex: 1514 Syslog, 12201 GELF) estejam liberadas no seu firewall (ufw ou iptables).

Recursos: O OpenSearch e o Graylog são baseados em Java. Para um ambiente de produção, você deve ter no mínimo 4GB de RAM, caso contrário, o serviço pode sofrer "OOM Kill" (Out of Memory).

Ajuste de JVM: Se o servidor tiver pouca memória, edite /etc/default/graylog-server e ajuste os parâmetros -Xms e -Xmx.

## 🛠️ O Script de Instalação Automatizada

Este script faz o seguinte:

Instala as dependências base.

Configura o MongoDB 6.0+.

Instala o OpenSearch 2.x (sucessor recomendado para o Graylog).

Instala o Graylog 6.x (versão atual).
