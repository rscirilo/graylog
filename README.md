# Projeto Integrador IFRN-PAR
### Aluno: Rodrigo Cirilo
### Tec. em Redes de Computadores

Automação de instalação do Graylog no Debian 13 (Trixie), com foco em laboratório, testes e documentação acadêmica do Projeto Integrador do IFRN.

Este repositório foi criado para facilitar a implantação do Graylog com poucos comandos, mantendo os arquivos, dados e logs dentro de `/srv`.

---

## Objetivo

O objetivo deste projeto é disponibilizar scripts para instalação automatizada do Graylog em ambiente Debian, reduzindo a configuração manual e facilitando a reprodução do ambiente em laboratório.

A proposta também serve como apoio para estudos de:

- Centralização de logs
- Observabilidade
- Monitoramento
- Segurança
- Documentação técnica

---

## Cenários do projeto

Este repositório foi pensado para dois cenários:

### 1. Ambiente sem AVX
Versão indicada para VMs ou processadores que não possuem suporte a AVX.

Exemplo de stack:
- Graylog 4.3.15
- MongoDB 4.4.29
- OpenSearch 1.3.14

### 2. Ambiente com AVX
Versão indicada para máquinas que possuem suporte a AVX e podem usar componentes mais novos.

Exemplo de stack:
- Graylog 5.x
- MongoDB 6.x
- OpenSearch 2.x

---

## Requisitos

### Requisitos mínimos

- Debian 13 (Trixie)
- Arquitetura `x86_64`
- Acesso com usuário que tenha permissão de `sudo`
- Internet para download dos pacotes e artefatos
- Espaço livre em `/srv`

### Recursos recomendados

Para laboratório:
- 2 vCPU
- 4 GB de RAM
- 20 GB de disco livre

Para uso mais estável:
- 4 vCPU
- 8 GB de RAM ou mais

---

## Preparação inicial

Antes de executar os scripts, atualize o sistema e instale o Git.

### 1. Atualizar a lista de pacotes

```bash
sudo apt update
```

Esse comando atualiza a lista de pacotes disponíveis no Debian.

### 2. Atualizar os pacotes instalados

```bash
sudo apt upgrade -y
```

Esse comando instala as atualizações disponíveis no sistema.

### 3. Instalar o Git

```bash
sudo apt install git -y
```

O Git será usado para clonar o repositório do projeto.

---

## Clonando o repositório

Depois de instalar o Git, entre no diretório `/srv` e clone o projeto.

### 1. Ir para `/srv`

```bash
cd /srv
```

O comando `cd` serve para trocar de diretório no terminal.

### 2. Clonar o repositório

```bash
git clone https://github.com/rscirilo/graylog.git
```

Esse comando cria uma cópia local do repositório em uma pasta chamada `graylog`.

### 3. Entrar no diretório do projeto

```bash
cd graylog
```

Agora você estará dentro da pasta do projeto.

---

## Execução dos scripts

### Script para ambiente sem AVX

Use este script quando a VM ou o processador não possuir suporte a AVX.

```bash
chmod +x install_graylog.sh
sudo ./install_graylog.sh
```

### Script para ambiente com AVX

Use este script quando a máquina possuir suporte a AVX.

```bash
chmod +x install_graylog_avx.sh
sudo ./install_graylog_avx.sh
```

---

## O que os scripts fazem

De forma geral, os scripts executam as seguintes etapas:

1. Fazem a pré-checagem do ambiente
2. Instalam dependências básicas
3. Configuram o Java
4. Instalam o MongoDB
5. Instalam o OpenSearch
6. Instalam o Graylog
7. Criam serviços `systemd`
8. Mantêm os dados em `/srv`

---

## Estrutura esperada

Exemplo de diretórios criados pelo script:

```bash
/srv/graylog4
├── config
├── data
├── downloads
├── graylog
├── java
├── log
├── mongodb
├── opensearch
└── run
```

Em versões mais novas, a estrutura pode variar para algo como:

```bash
/srv/graylog5
├── config
├── data
├── downloads
├── graylog
├── java
├── log
├── mongodb
├── opensearch
└── run
```

---

## Portas importantes

Verifique o firewall, roteamento e regras locais antes de acessar ou integrar o ambiente.

Portas principais:
- `9000` — interface web e API do Graylog
- `9200` — OpenSearch
- `27017` — MongoDB

Portas comuns de entrada de logs:
- `1514` — Syslog
- `12201` — GELF
- `5044` — Beats, caso seja configurado depois

---

## Validação rápida

Após a instalação, você pode validar os serviços com:

### Versão sem AVX

```bash
systemctl status mongod-graylog
systemctl status opensearch-graylog
systemctl status graylog-tarball
ss -ltnp | grep 9000
```

### Versão com AVX

```bash
systemctl status mongod-graylog-avx
systemctl status opensearch-graylog-avx
systemctl status graylog-avx
ss -ltnp | grep 9000
```

---

## Acesso ao Graylog

Depois que a instalação terminar, abra no navegador:

```bash
http://IP_DO_SERVIDOR:9000
```

Usuário inicial:

```text
admin
```

A senha inicial será exibida no final da execução do script.

---

## Observações

- A versão sem AVX foi criada para contornar a limitação de CPUs que não suportam MongoDB 5+
- A instalação via tarball foi adotada para reduzir dependência de repositórios `apt`
- O projeto foi pensado para laboratório, testes e documentação acadêmica
- Recomenda-se criar snapshot da VM antes de mudanças maiores

---

## Finalidade acadêmica

Este material foi preparado como apoio ao **Projeto Integrador IFRN-PAR**, com foco em automação, padronização, documentação e reprodutibilidade da instalação do Graylog em Debian.

---

## Licença

Este projeto está licenciado sob a licença MIT.

Você pode usar, copiar, modificar e distribuir este projeto, desde que mantenha o aviso de copyright e o texto da licença.

Para mais detalhes, consulte o arquivo [LICENSE](./LICENSE).

## contribuições é sempre bem-vindas
