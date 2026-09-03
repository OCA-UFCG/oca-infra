# nginx nos hosts de produção — baseline comum e divergências

Levantamento feito em **2026-09-02** por inspeção direta (`nginx -T` dentro do container)
dos três hosts EC2 que servem os portais.

| Apelido | App servida | Domínios |
|---|---|---|
| `datane`  | `data-nordeste-frontend` | `datanordeste-portal.com`, `datanordeste.sudene.gov.br` |
| `sap`     | `SAP-frontend` (+ multicriterial, MCP) | `sap.oca-portal.com`, `sap.lsd.ufcg.edu.br`, `sedes.oca-portal.com` |
| `carbono` | `plataforma-carbono-mvp` | `carbono-caatinga.oca.ufcg.edu.br`, `carbono-caatinga.oca-portal.com` |

---

## 1. O baseline comum

Os três hosts seguem o mesmo desenho. Isso **não é coincidência**: todos descendem do
template ansible deste repositório (`ansible/roles/deploy/templates/`), copiado e
editado à mão em cada máquina. Ver §3.

### 1.1 nginx roda em container, nunca no host

Em todos os três o proxy é um container `nginx:latest` com `restart: always`,
publicando `80:80` e `443:443` no host. O pacote `nginx` do sistema só existe no
`datane`, e está `inactive` — é resíduo, não serve tráfego.

> Consequência prática: `systemctl status nginx` engana. Para mexer em config é
> sempre `docker exec <nginx> nginx -t && docker exec <nginx> nginx -s reload`.

### 1.2 A config entra por bind-mount read-only em `conf.d`

```
/home/ubuntu/nginx  ->  /etc/nginx/conf.d   (ro)
```

Idêntico nos três. O `nginx.conf` da imagem oficial **nunca é tocado** — é byte a byte
o default do upstream nos três hosts (`worker_connections 1024`,
`keepalive_timeout 65`, gzip comentado, `include /etc/nginx/conf.d/*.conf`).
Toda a customização vive em um único `<projeto>.conf` dentro de `/home/ubuntu/nginx/`.

### 1.3 Só faz reverse proxy — nunca serve arquivo estático

Nenhum `root` em bloco de aplicação. Todo `location /` é `proxy_pass` para o container
Next.js na porta 3000, resolvido por **DNS do Docker pelo nome do container**, numa
bridge network dedicada compartilhada entre nginx e app:

| Host | upstream | network |
|---|---|---|
| `datane`  | `http://data-nordeste-frontend-app:3000` | `datane-network` |
| `sap`     | `http://sap-home-frontend:3000`          | `sap-network` |
| `carbono` | `http://carbono-caatinga:3000`           | `sap-network` ⚠️ |

⚠️ O host do carbono usa uma rede chamada `sap-network`. O nome está errado para o que
a máquina faz (provavelmente veio de cópia de AMI ou copy-paste). Funciona, mas engana
quem for debugar.

### 1.4 Porta 80 só existe para ACME + redirect

Padrão idêntico nos três, e é o único papel do bloco `:80`:

```nginx
server {
    listen 80;
    server_name <dominios>;

    location /.well-known/acme-challenge/ { root <webroot>; }
    location / { return 301 https://$host$request_uri; }
}
```

### 1.5 TLS com Let's Encrypt via desafio webroot, renovado por systemd timer

Todos usam certbot no modo webroot (nunca `--nginx`, nunca DNS-01), disparado por timer
do systemd. O *como* diverge bastante — ver §2.

### 1.6 Cada host serve a mesma app sob dois domínios

Sempre um par: um domínio `*.oca-portal.com` (ou legado) e um institucional
(`sudene.gov.br`, `lsd.ufcg.edu.br`, `oca.ufcg.edu.br`). São blocos `server` separados,
com certificados separados, apontando para o mesmo upstream.

---

## 2. Onde os três divergem

Esta é a parte que interessa: o baseline é comum, o resto derivou.

| | `datane` | `sap` | `carbono` |
|---|---|---|---|
| SO | Ubuntu 24.04.2 | Ubuntu 24.04.4 | Ubuntu 26.04 |
| Container nginx | `ubuntu-nginx-1` | `nginx` | `nginx` |
| Orquestração | `docker-compose.yml` | `docker run` avulso | `docker run` avulso |
| Onde o nginx lê o cert | `/etc/letsencrypt/live/...` | `/etc/nginx/ssl/*.pem` (cópias planas) | `/etc/letsencrypt/live/...` |
| Origem do cert | `/etc/letsencrypt` do host (mount) | `/home/ubuntu/ssl` (mount) | `/home/ubuntu/certbot/conf` (mount) |
| Webroot ACME | `/var/www/html` | `/var/www/certbot` | `/var/www/certbot` |
| certbot | pacote do host + `certbot.timer` | pacote do host + `certbot.timer` | **container** `certbot/certbot` + `certbot-renew.timer` custom |
| **Reload do nginx pós-renovação** | ✅ deploy hook | ✅ deploy hook (+ cópia dos certs) | ✅ `ExecStartPost` faz `nginx -t && nginx -s reload` |
| Params SSL Mozilla | ✅ `options-ssl-nginx.conf` + `ssl_dhparam` | ❌ | ❌ |
| `proxy_cache` | ✅ 2 zonas (`my_cache`, `my_cache2`) | ✅ 1 zona (`my_cache`) | ❌ |
| `X-Real-IP` / `X-Forwarded-For` | ❌ só `Host` | ✅ | ✅ |
| `X-Forwarded-Proto` | ❌ | ❌ | ✅ |
| Upgrade WebSocket | ✅ | ❌ | ✅ |
| `server_tokens off` | ❌ | ✅ | ❌ |
| `listen [::]` (IPv6) | ✅ | ❌ | ✅ |
| Endpoint `/health` | proxy p/ app | `return 200 "ok"` | ❌ |
| Observabilidade | node-exporter, nginx-exporter, `stub_status` :8080 | ❌ | ❌ |

### Notas por host

**`datane`** — o mais elaborado. Único com cache de verdade (inclusive um segundo zone,
`my_cache2`, que cacheia **POST** para a API GraphQL do Contentful via
`/contentful-api`, com `proxy_cache_key` incluindo `$request_body`). Único instrumentado
para Prometheus. Mas é o único que **não repassa o IP do cliente** — a app enxerga
sempre o IP do container nginx.

**`sap`** — o mais peculiar no TLS. Os `.pem` que o nginx lê em `/home/ubuntu/ssl/` são
**cópias planas** tiradas do `/etc/letsencrypt`. Até 2026-09 essa cópia era feita à mão;
hoje um deploy hook a refaz automaticamente (§5). Também é o único host que serve três
domínios — e o terceiro, `sedes.oca-portal.com`, lê de um caminho diferente
(`/etc/nginx/ssl/live/sedes.oca-portal.com/`) porque vive num **config-dir de certbot
separado**, `/home/ubuntu/ssl`. Como o `certbot.timer` do sistema usa o config-dir
padrão, **essa lineage não é renovada automaticamente** — ver §4.

**`carbono`** — o mais limpo e o mais próximo de reproduzível: não tem nada de nginx nem
de certbot instalado no host, é 100% container. É o único com o ciclo de renovação
fechado corretamente (renova e recarrega). Em contrapartida, é o mais pobre — sem cache,
sem métricas, sem `server_tokens off`.

---

## 3. De onde veio esse padrão

O ancestral comum está neste repositório:

- `ansible/roles/deploy/templates/docker-compose.yml`
- `ansible/roles/deploy/templates/nginx/oca.conf`

O template já traz o baseline inteiro: `nginx:latest`, `80:80`/`443:443`,
`restart: always`, `./nginx/:/etc/nginx/conf.d/:ro`, `./ssl/:/etc/nginx/ssl/:ro`, bridge
network dedicada, `proxy_pass http://{{ container_name }}:3000` e o bloco `:80` de
redirect. O `client_max_body_size 6G` que sobrevive no `datane.conf` vem literalmente
daqui.

O que o template **não** cobre, e por isso cada host resolveu do seu jeito:
não tem Let's Encrypt (assume certs `lsd.*` colocados à mão em `./certs`), não tem
webroot ACME, não tem `X-Forwarded-*`, não tem cache e não tem reload pós-renovação.

**Todas as três divergências relevantes da §2 são exatamente as lacunas do template.**

---

## 4. Pendências identificadas

Em ordem de risco:

1. ~~**`datane` e `sap` não recarregam o nginx depois de renovar o certificado.**~~
   **Resolvido em 2026-09-03** — ver §5. Este item chegou a causar incidente: o
   `datane` serviu certificado vencido por algumas horas.
2. ~~**`sap`: certificados copiados à mão** para `/home/ubuntu/ssl/`.~~
   **Resolvido em 2026-09-03** — o deploy hook refaz a cópia. A melhoria estrutural
   (montar `/etc/letsencrypt` direto, como fazem os outros dois) continua valendo.
3. **Lineages órfãs com authenticator incompatível quebram `certbot renew` nos dois
   hosts.** Este é o achado mais importante do levantamento, e vale como regra geral:
   **com o nginx em container, os authenticators `nginx` e `standalone` não funcionam.**
   Ambos precisam das portas 80/443, que o container já ocupa:

   ```
   # authenticator = nginx  (datane)
   MisconfigurationError: nginx restart failed:
   nginx: [emerg] bind() to 0.0.0.0:443 failed (98: Address already in use)

   # authenticator = standalone  (sap)
   Could not bind TCP port 80 because it is already in use by another process
   ```

   Só `webroot` serve — e é o que as lineages saudáveis usam.

   | Host | Lineage | Authenticator | Estado |
   |---|---|---|---|
   | `datane` | `datanordeste-portal.com` (SAN, cobre os 2 domínios) | `webroot` | ✅ renova |
   | `datane` | `datanordeste.sudene.gov.br` | `nginx` | ❌ falha sempre — **e é redundante**, o SAN acima já cobre esse domínio |
   | `sap` | `sap.oca-portal.com` | `webroot` | ✅ renova |
   | `sap` | `sap.lsd.ufcg.edu.br` | `webroot` | ❔ inconclusivo — ver nota abaixo |
   | `sap` | `analise-multicriterial.oca-portal.com` | `standalone` | ❌ falha sempre — **vencida desde 2026-07-27**; o DNS aponta para `150.165.85.28`, que não é este host |

   Como uma lineage quebrada faz `certbot renew` terminar com status de erro, o timer
   falha em toda execução e o sinal real fica enterrado. Foi assim que o vencimento no
   `datane` passou despercebido.

   A remoção das duas órfãs é a correção recomendada — **ainda não executada, pendente
   de decisão**:

   ```bash
   # datane
   sudo certbot delete --cert-name datanordeste.sudene.gov.br
   # sap
   sudo certbot delete --cert-name analise-multicriterial.oca-portal.com
   ```

   > **Sobre o `sap.lsd.ufcg.edu.br`:** ele falhou nos dry-runs de 2026-09-03, primeiro
   > com `authorization must be pending` e depois com `rateLimited :: Service busy`.
   > O segundo erro é limite do servidor **de staging**, atingido por dry-runs repetidos
   > em sequência — ou seja, provavelmente ruído do próprio teste, e não defeito da
   > lineage. Sua configuração é `webroot`, idêntica à do `sap.oca-portal.com`, que
   > renovou com sucesso. **O estado dele é inconclusivo**; precisa de um novo
   > `certbot renew --dry-run --cert-name sap.lsd.ufcg.edu.br` depois de algumas horas
   > sem outras tentativas. Vence em 2026-11-23, então há folga.
4. **Segredo em texto plano na config do `datane`.** O bloco `/contentful-api` do
   `datane.conf` carrega um token do Contentful hardcoded em
   `proxy_set_header Authorization "Bearer ..."`. Precisa sair do arquivo (variável de
   ambiente / secret) e **o token deve ser rotacionado**, já que esteve em disco sem
   proteção. *(O valor foi deliberadamente omitido deste documento.)*
5. **`sedes.oca-portal.com` tem dois defeitos de renovação.** Vence em **2026-10-18**.
   Primeiro, a lineage vive em `/home/ubuntu/ssl`, um config-dir separado que o
   `certbot.timer` do sistema não enxerga — nunca é renovada automaticamente. Segundo,
   seu `webroot_path` é `/var/www/certbot`, que é o caminho **de dentro do container**;
   no host esse diretório existe mas está vazio, e o webroot real é
   `/home/ubuntu/certbot/www`. Mesmo rodando à mão o desafio ACME cairia no lugar
   errado. O certo é migrar a lineage para `/etc/letsencrypt` com o webroot correto.
6. **`datane` não envia `X-Real-IP` / `X-Forwarded-For`** — logs e qualquer
   rate-limit/geo da app estão cegos.
7. **`nginx:latest` sem pin nos três.** Um `docker pull` pode trocar a versão major
   sem aviso.
8. **`ssl_protocols` sem restrição em `sap` e `carbono`** — só o `datane` fixa
   TLS 1.2/1.3 (via `options-ssl-nginx.conf`). Vale padronizar.
9. **Sem `default_server` de catch-all em TLS.** Requisição com `Host` desconhecido cai
   no primeiro bloco `server`, respondendo com um certificado que não bate.
10. Resíduos: `sites-enabled/default` do pacote no `datane`,
   `carbono.conf.bak-20260828-171642` no `carbono` (não é carregado, o include é
   `*.conf`), e `multic-*.pem` no `sap` **vencido em 2026-07-27** e não referenciado.

---

## 5. Renovação de certificados e reload automático

Instalado em **2026-09-03**, portando para os outros dois hosts o que o `carbono` já
fazia. O princípio é o mesmo nos três: **depois que o certbot renova, alguém precisa
mandar o nginx recarregar** — o processo tem o certificado antigo carregado em memória
desde que subiu e não o relê sozinho.

### Por que isso importa

O `datane` rodou com o container de pé desde 2025-09-08 sem nenhum reload. O certbot
renovou os certificados normalmente durante todo esse período, mas o nginx seguiu
servindo o que carregou na inicialização. Em **2026-09-02** esse certificado venceu e
`datanordeste-portal.com` passou a dar aviso de segurança no navegador, mesmo com o
certificado válido em disco. Um `nginx -s reload` resolveu na hora.

### `carbono` — `ExecStartPost` na unit systemd

O certbot roda em container, então o reload vive no próprio serviço de renovação:

```ini
# /etc/systemd/system/certbot-renew.service
ExecStart=/usr/bin/docker run --rm \
  -v /home/ubuntu/certbot/www:/var/www/certbot \
  -v /home/ubuntu/certbot/conf:/etc/letsencrypt \
  certbot/certbot renew --quiet
ExecStartPost=/bin/sh -c '/usr/bin/docker exec nginx nginx -t && /usr/bin/docker exec nginx nginx -s reload'
```

### `datane` e `sap` — deploy hook do certbot

Nesses dois o certbot é pacote do sistema e roda pelo `certbot.timer` padrão, então o
lugar certo é `/etc/letsencrypt/renewal-hooks/deploy/`: o certbot executa tudo que
estiver lá, uma vez por lineage, **só quando a renovação de fato acontece**. Não requer
mexer na unit do pacote.

O hook de reload **é gerado pelo role `deploy`** deste repositório
(`ansible/roles/deploy/templates/letsencrypt/reload-nginx.sh`), então máquinas novas já
nascem com ele — não repita a instalação à mão. O nome do container vem da var
`nginx_container_name`. O hook sai com 0 quando o container não está rodando: um
container parado não é falha de renovação.

| Host | Hook | O que faz |
|---|---|---|
| `datane` | `/etc/letsencrypt/renewal-hooks/deploy/00-reload-nginx.sh` | `nginx -t` + `nginx -s reload` no container `ubuntu-nginx-1` |
| `sap` | `/etc/letsencrypt/renewal-hooks/deploy/00-sync-certs-reload-nginx.sh` | copia as lineages para os `.pem` planos de `/home/ubuntu/ssl/`, depois `nginx -t` + reload |
| `sap` (sedes) | `/home/ubuntu/ssl/renewal-hooks/deploy/00-reload-nginx.sh` | reload, para quando o config-dir separado for renovado |

O hook do `sap` é a exceção: **não vem do role**, e é maior porque lá o nginx não lê de
`/etc/letsencrypt` — lê cópias planas. Ele refaz a cópia preservando as permissões
(`0644` na fullchain, `0600` na privkey) e só então recarrega. Codificar essa
particularidade no ansible seria enraizar a gambiarra; o certo é migrar o host para o
layout padrão (§4.2), e aí ele passa a usar o hook do role como os outros.

```sh
sync_cert sap.oca-portal.com  ""      # -> ssl/fullchain.pem     + ssl/privkey.pem
sync_cert sap.lsd.ufcg.edu.br "lsd-"  # -> ssl/lsd-fullchain.pem + ssl/lsd-privkey.pem
```

### Testar sem esperar a renovação

Os hooks são idempotentes — dá para rodar à mão a qualquer momento:

```bash
sudo /etc/letsencrypt/renewal-hooks/deploy/00-*.sh
```

E para validar o ciclo inteiro sem gastar cota do Let's Encrypt:

```bash
sudo certbot renew --dry-run
```

Vale rodar isso periodicamente: foi o `--dry-run` que expôs as lineages quebradas
descritas em §4.3, nos dois hosts. O `certbot renew` já vinha falhando havia meses —
só que ninguém olhava o status de saída.

### Conferir qual certificado está realmente sendo servido

O ponto cego que causou o incidente: o arquivo em disco pode estar renovado enquanto o
nginx serve outro. Compare os dois lados.

```bash
# em disco
sudo openssl x509 -in /etc/letsencrypt/live/<dominio>/fullchain.pem -noout -enddate -serial

# o que o nginx está servindo de fato
echo | openssl s_client -connect 127.0.0.1:443 -servername <dominio> 2>/dev/null \
  | openssl x509 -noout -enddate -serial
```

Serial diferente entre os dois = falta reload.

> Cuidado ao testar de fora: `datanordeste.sudene.gov.br` responde com um certificado
> diferente do da origem porque está atrás de um proxy/CDN que termina TLS por conta
> própria. Para esse domínio, só o teste local (`127.0.0.1`) reflete o estado do nginx.

---

## 6. Como mexer na config (runbook)

Igual nos três, mudando só o nome do container:

```bash
# 1. editar
sudo vim /home/ubuntu/nginx/<projeto>.conf

# 2. validar ANTES de recarregar
sudo docker exec <nginx|ubuntu-nginx-1> nginx -t

# 3. recarregar sem derrubar conexões
sudo docker exec <nginx|ubuntu-nginx-1> nginx -s reload
```

O mount é `:ro`, então editar no host e recarregar basta — não precisa recriar o
container. Reiniciar o container só é necessário se mudar porta, volume ou rede.
