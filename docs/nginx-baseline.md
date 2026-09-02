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
| **Reload do nginx pós-renovação** | ❌ nenhum hook | ❌ nenhum hook | ✅ `ExecStartPost` faz `nginx -t && nginx -s reload` |
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

**`sap`** — o mais frágil no TLS. Os `.pem` que o nginx lê em `/home/ubuntu/ssl/` são
**cópias planas** tiradas do `/etc/letsencrypt`, e não há nenhum deploy hook que refaça
essa cópia. Ou seja: `certbot renew` roda, renova em `/etc/letsencrypt`, e o nginx
continua servindo a cópia velha até alguém copiar na mão. Também é o único host que
serve três domínios (o terceiro, `sedes.oca-portal.com`, lê de um caminho diferente:
`/etc/nginx/ssl/live/sedes.oca-portal.com/`).

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

1. **`datane` e `sap` não recarregam o nginx depois de renovar o certificado.**
   Risco real de servir certificado expirado. `carbono` já tem a solução pronta
   (`certbot-renew.service` com `ExecStartPost`) — dá para portar como deploy hook em
   `/etc/letsencrypt/renewal-hooks/deploy/`.
2. **`sap`: certificados copiados à mão** para `/home/ubuntu/ssl/`. Combinado com o
   item 1, é o ponto mais provável de falha. O ideal é montar `/etc/letsencrypt`
   direto, como fazem os outros dois.
3. **Segredo em texto plano na config do `datane`.** O bloco `/contentful-api` do
   `datane.conf` carrega um token do Contentful hardcoded em
   `proxy_set_header Authorization "Bearer ..."`. Precisa sair do arquivo (variável de
   ambiente / secret) e **o token deve ser rotacionado**, já que esteve em disco sem
   proteção. *(O valor foi deliberadamente omitido deste documento.)*
4. **`datane` não envia `X-Real-IP` / `X-Forwarded-For`** — logs e qualquer
   rate-limit/geo da app estão cegos.
5. **`nginx:latest` sem pin nos três.** Um `docker pull` pode trocar a versão major
   sem aviso.
6. **`ssl_protocols` sem restrição em `sap` e `carbono`** — só o `datane` fixa
   TLS 1.2/1.3 (via `options-ssl-nginx.conf`). Vale padronizar.
7. **Sem `default_server` de catch-all em TLS.** Requisição com `Host` desconhecido cai
   no primeiro bloco `server`, respondendo com um certificado que não bate.
8. Resíduos: `sites-enabled/default` do pacote no `datane`,
   `carbono.conf.bak-20260828-171642` no `carbono` (não é carregado, o include é
   `*.conf`), e `multic-*.pem` no `sap` **vencido em 2026-07-27** e não referenciado.

---

## 5. Como mexer na config (runbook)

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
