# Projeto Integrador IFRN-PAR
### Aluno: Rodrigo Cirilo
### Tec. em Redes de Computadores

Repositório oficial deste guia e script: [github.com/rscirilo/graylog](https://github.com/rscirilo/graylog)

Automação de instalação do Graylog no Debian 13 (Trixie), com foco em laboratório, testes e documentação acadêmica do Projeto Integrador do IFRN.

# Guia de Instalação – Graylog 4.3 + MongoDB 4.4 + Elasticsearch 7.10.2  
Ambiente: Debian 13 (Trixie) sem AVX – IFRN Parnamirim

Este guia foi pensado para o pessoal do IFRN (curso Técnico Subsequente em Redes) instalar o Graylog **copiando e colando comandos**, em uma VM Debian 13 (Trixie) sem suporte a AVX.

> Resultado final: Graylog 4.3 rodando em `http://IP_DA_VM:9000`  
> Usuário: `admin`  
> Senha: `integrador2026`

---

## 1. Pré‑requisitos da VM

- Sistema: **Debian 13 (Trixie)** 64 bits.
- CPU: sem suporte a AVX (laboratório IFRN).
- A VM deve ter:
  - Pelo menos **2 vCPUs**.
  - Pelo menos **4 GB de RAM** (recomendado 6–8 GB).
  - Pelo menos **30 GB de disco**.
- Ter acesso à Internet para baixar pacotes.

Verificar versão do sistema:

```bash
lsb_release -a && uname -m
```

O esperado é algo como: `Debian GNU/Linux 13 (trixie)` e `x86_64`.

---

## 2. Atualizar o sistema

```bash
sudo apt-get update
sudo apt-get upgrade -y
```

Instalar utilitários básicos:

```bash
sudo apt-get install -y curl wget nano pwgen gnupg apt-transport-https ca-certificates lsb-release net-tools
```

---

## 3. Instalar MongoDB 4.4 via arquivos .deb

Como o servidor do laboratório **não tem AVX**, não podemos usar MongoDB 5 ou 7.  
Vamos instalar o **MongoDB 4.4.30** usando pacotes `.deb` locais.

### 3.1. Criar pasta para os pacotes

```bash
sudo mkdir -p /srv/mongodb-debs
cd /srv/mongodb-debs
```

### 3.2. Baixar os pacotes necessários (Debian 11 – compatível)

```bash
sudo wget https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/4.4/main/binary-amd64/libssl1.1_1.1.1n-0+deb11u5_amd64.deb
sudo wget https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/4.4/main/binary-amd64/mongodb-org-server_4.4.30_amd64.deb
sudo wget https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/4.4/main/binary-amd64/mongodb-org-mongos_4.4.30_amd64.deb
sudo wget https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/4.4/main/binary-amd64/mongodb-org-shell_4.4.30_amd64.deb
sudo wget https://repo.mongodb.org/apt/debian/dists/bullseye/mongodb-org/4.4/main/binary-amd64/mongodb-org-database-tools-extra_4.4.30_amd64.deb
```

### 3.3. Instalar os pacotes

```bash
cd /srv/mongodb-debs

sudo dpkg -i libssl1.1_1.1.1n-0+deb11u5_amd64.deb
sudo dpkg -i mongodb-org-server_4.4.30_amd64.deb mongodb-org-mongos_4.4.30_amd64.deb mongodb-org-shell_4.4.30_amd64.deb mongodb-org-database-tools-extra_4.4.30_amd64.deb || sudo apt-get install -f -y
```

### 3.4. Habilitar e testar o MongoDB

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mongod
sleep 5
mongo --eval "db.adminCommand({serverStatus:1}).version"
```

Se aparecer `MongoDB server version: 4.4.30` e, na última linha, `4.4.30`, o MongoDB está OK.

---

## 4. Instalar Elasticsearch 7.10.2

O Graylog 4.3 funciona bem com Elasticsearch 7.10.x.

### 4.1. Adicionar repositório da Elastic

```bash
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elasticsearch-7.x.list

sudo apt-get update
```

### 4.2. Instalar Elasticsearch

```bash
sudo apt-get install -y elasticsearch=7.10.2
```

### 4.3. Configurar Elasticsearch para Graylog

Editar o arquivo de configuração:

```bash
sudo nano /etc/elasticsearch/elasticsearch.yml
```

Conteúdo mínimo recomendado (adicione/ajuste estas linhas):

```yaml
cluster.name: graylog
node.name: integrador2026
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

network.host: 0.0.0.0
http.port: 9200

discovery.type: single-node
```

Salvar e sair (`Ctrl+O`, Enter, `Ctrl+X`).

### 4.4. Habilitar e testar Elasticsearch

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now elasticsearch
sleep 15
curl -s http://localhost:9200
```

A saída deve mostrar versão `7.10.2` e `cluster_name` igual a `graylog`.

---

## 5. Instalar Graylog 4.3.15

O repositório oficial Graylog usa assinatura antiga (SHA1), então vamos marcar como confiável especificamente para este uso.

### 5.1. Adicionar repositório Graylog 4.3

```bash
wget -qO /tmp/graylog-4.3-repository_latest.deb https://packages.graylog2.org/repo/packages/graylog-4.3-repository_latest.deb
sudo dpkg -i /tmp/graylog-4.3-repository_latest.deb
```

Se der erro de assinatura SHA1, vamos forçar o repositório como confiável:

```bash
echo "deb [trusted=yes] https://packages.graylog2.org/repo/debian/ stable 4.3" | sudo tee /etc/apt/sources.list.d/graylog.list
sudo apt-get update
```

### 5.2. Instalar Graylog Server

```bash
sudo apt-get install -y graylog-server
```

Ao final, o instalador avisa que o serviço **não inicia automaticamente**.

---

## 6. Configurar o Graylog

Arquivo principal: `/etc/graylog/server/server.conf`

### 6.1. Definir senha do usuário admin

A senha será: `integrador2026`.

Gerar o hash SHA256:

```bash
echo -n "integrador2026" | sha256sum | awk '{print $1}'
```

Copie o hash retornado (uma sequência grande de números/letras).

### 6.2. Gerar password_secret

```bash
sudo apt-get install -y pwgen
pwgen -N 1 -s 96
```

Copie a sequência gerada (grande, aleatória).

### 6.3. Editar o arquivo server.conf

Abra:

```bash
sudo nano /etc/graylog/server/server.conf
```

Procure e ajuste estas linhas (adicione se não existirem):

```ini
# segredo aleatório (password_secret)
password_secret = COLE_AQUI_O_VALOR_DO_PWGEN

# hash da senha do usuário admin (root_password_sha2)
root_password_sha2 = COLE_AQUI_O_HASH_DO_SHA256_DA_SENHA

# MongoDB
mongodb_uri = mongodb://localhost/graylog

# Elasticsearch
elasticsearch_hosts = http://localhost:9200

# Interface web – ouvir em todas as interfaces, porta 9000
http_bind_address = 0.0.0.0:9000

# URL que os clientes usam para acessar (coloque o IP DA VM)
http_publish_uri = http://IP_DA_VM:9000/

# Journal – reduzir para caber em disco (ex: 1 GB)
message_journal_max_size = 1gb
```

Substitua:
- `COLE_AQUI_O_VALOR_DO_PWGEN` pelo valor gerado pelo `pwgen`.
- `COLE_AQUI_O_HASH_DO_SHA256_DA_SENHA` pelo hash da senha `integrador2026`.
- `IP_DA_VM` pelo IP real da VM, por exemplo `192.168.100.2`.

Salvar e sair (`Ctrl+O`, Enter, `Ctrl+X`).

---

## 7. Iniciar Graylog e testar

### 7.1. Habilitar o serviço na inicialização

```bash
sudo systemctl enable --now graylog-server
```

Espere um pouco (30–40 segundos) e teste:

```bash
sleep 30
curl -s -o /dev/null -w "%{http_code}" http://localhost:9000/api/system/lbstatus
```

Se retornar `200`, o Graylog está ok.

Se retornar `000` ou erro, ver log:

```bash
sudo journalctl -eu graylog-server --no-pager | tail -40
```

Erros comuns:
- Falta de espaço para o journal: ajustar `message_journal_max_size` para valor menor.
- Erro de conexão com Elasticsearch ou MongoDB: conferir serviços e configurações.

---

## 8. Acessar a interface web

Do seu navegador (no PC da rede do laboratório):

1. Descobrir IP da VM:

   ```bash
   ip a
   ```

   Exemplo: `192.168.100.2`.

2. No navegador:

   - URL: `http://192.168.100.2:9000/`  
   - Usuário: `admin`  
   - Senha: `integrador2026`

Se não abrir:
- Verifique se a porta 9000 está ouvindo em todas as interfaces:

  ```bash
  sudo ss -ltpn | grep 9000
  ```

  O ideal é ver algo como: `LISTEN *:9000`.

- Verificar se não há firewall bloqueando a porta 9000 (iptables/nftables ou firewall externo).

---

## 9. Próximos passos (para a turma)

Depois de acessar a interface:

- Ajustar o fuso horário do usuário em:  
  `System -> Users -> admin -> Edit -> Timezone`.
- Criar um **Input** para receber logs, por exemplo:
  - `System -> Inputs -> Syslog UDP 514` (pfSense, Mikrotik etc).
  - `System -> Inputs -> GELF UDP/TCP` (aplicações com agentes).
- Apontar os dispositivos (roteadores, firewalls, servidores) para enviar logs para o IP da VM do Graylog na porta correta.

---

## 10. Resumo rápido (cola final)

Para quem quiser a “cola seca” depois de entender:

```bash
# Atualizar sistema
sudo apt-get update && sudo apt-get upgrade -y

# MongoDB 4.4
sudo mkdir -p /srv/mongodb-debs && cd /srv/mongodb-debs
# (baixar os 5 .deb do MongoDB 4.4 – ver seção 3.2)
sudo dpkg -i libssl1.1_*.deb
sudo dpkg -i mongodb-org-*_4.4.30_amd64.deb || sudo apt-get install -f -y
sudo systemctl enable --now mongod

# Elasticsearch 7.10.2
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elasticsearch-7.x.list
sudo apt-get update
sudo apt-get install -y elasticsearch=7.10.2
sudo systemctl enable --now elasticsearch

# Graylog 4.3
wget -qO /tmp/graylog-4.3-repository_latest.deb https://packages.graylog2.org/repo/packages/graylog-4.3-repository_latest.deb
sudo dpkg -i /tmp/graylog-4.3-repository_latest.deb
echo "deb [trusted=yes] https://packages.graylog2.org/repo/debian/ stable 4.3" | sudo tee /etc/apt/sources.list.d/graylog.list
sudo apt-get update
sudo apt-get install -y graylog-server

# Configurar /etc/graylog/server/server.conf
# (password_secret com pwgen, root_password_sha2 com echo -n "integrador2026" | sha256sum)
# http_bind_address = 0.0.0.0:9000
# http_publish_uri = http://IP_DA_VM:9000/
# message_journal_max_size = 1gb

# Iniciar Graylog
sudo systemctl enable --now graylog-server
sleep 30
curl -s -o /dev/null -w "%{http_code}" http://localhost:9000/api/system/lbstatus
```

---
