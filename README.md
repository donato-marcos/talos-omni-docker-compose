# Talos Omni Stack

Stack self-hosted do [Sidero Omni](https://www.siderolabs.com/omni/) rodando em Docker Compose, com **Traefik** (TLS via Let's Encrypt DNS-01 Cloudflare) e **Dex** (provedor OIDC local). Projetada para gerenciar clusters **Talos Linux** em laboratório ou ambientes on-premises.

> ⚠️ **Uso em produção**: o Omni é licenciado sob BSL e requer contrato comercial da Sidero Labs para uso produtivo. Este projeto é voltado para **homelab e laboratório**, coberto pela licença gratuita. Veja a seção [Licença](#-licença).


## 📐 Arquitetura

```
                        ┌─────────────────────────────────────────┐
   Internet / LAN       │              Host Docker                │
                        │                                         │
   omni.dominio  ──────►│  Traefik :443  ──►  Omni :8080 (h2c)    │
   auth.dominio  ──────►│       :8090    ──►  Omni :8090 (h2c)    │
   *.omni.dominio ─────►│       :8100    ──►  Omni :8100 (http)   │
                        │                                         │
   WireGuard UDP ──────►│  Omni :50180/udp (SideroLink)           │
                        │                                         │
                        │  Dex :5556 (OIDC, HTTP interno)         │
                        └─────────────────────────────────────────┘
                                        ▲
                                        │ SideroLink
                                        │ (WireGuard)
                        ┌───────────────┴─────────────────────────┐
                        │          Nós Talos Linux                │
                        │   (VMs, bare metal ou cloud)            │
                        │   criados a partir da imagem do Omni    │
                        └─────────────────────────────────────────┘
```

**Componentes**:

| Componente | Papel |
| :--- | :--- |
| **Omni** | Plano de controle: gerencia máquinas, clusters, upgrades e acesso. |
| **Traefik** | Reverse proxy com terminação TLS (Let's Encrypt DNS-01). Encaminha para o Omni via **h2c** (gRPC) e **http**. |
| **Dex** | Provedor OIDC local com usuário estático, autenticando no Omni. |

**Decisões de design**:

- O **Omni não gerencia TLS próprio**. Ele serve h2c/http internamente, e o Traefik faz toda a terminação TLS. Isso elimina a necessidade de certificados internos e simplifica a rotação.
- A porta **50180/UDP** (WireGuard) é publicada **diretamente** pelo container do Omni, pois não passa pelo Traefik.
- O Omni usa **etcd embutido** (padrão) e **SQLite** para estado auxiliar, ambos persistidos em volumes locais.
- A autenticação é **OIDC via Dex**, sem dependência de provedores externos (Auth0, Azure AD, etc.).
- As VMs Talos são criadas a partir de uma **imagem gerada pelo próprio Omni** (não de uma ISO padrão do Talos), garantindo que o join token e o endpoint SideroLink já venham embutidos.


## 📋 Pré-requisitos

### No host Docker

- **Docker Engine** com **Docker Compose v2.20+** (necessário para `include`).
- **Domínio** com DNS gerenciado no **Cloudflare** (para o DNS-01 challenge).
- **Token de API do Cloudflare** com permissão `Zone:DNS:Edit`.
- **Portas abertas** no firewall:

| Porta | Protocolo | Propósito |
| :--- | :--- | :--- |
| 80 | TCP | Redirecionamento HTTP → HTTPS (Traefik) |
| 443 | TCP | UI/API do Omni e Dex (Traefik) |
| 8090 | TCP | SideroLink Machine API (Traefik) |
| 8091 | TCP | Event sink do Omni (direto) |
| 8100 | TCP | Kubernetes proxy (Traefik) |
| 50180 | UDP | WireGuard / SideroLink (direto) |

- **Ferramentas**: `gpg`, `openssl`, `curl`, `iproute2` (para `ip route`).

### Registros DNS necessários

Todos apontando para o IP do host Docker, **sem proxy Cloudflare** (nuvem cinza):

| Registro | Propósito |
| :--- | :--- |
| `omni.<dominio>` | UI e API principal |
| `auth.<dominio>` | Dex (provedor OIDC) |
| `kubernetes.<dominio>` | Kubernetes proxy |
| `siderolink.<dominio>` | SideroLink Machine API |
| `*.omni.<dominio>` | Workload Proxy (opcional) |

> O `HOST_PUBLIC_IP` usado no WireGuard deve ser um IP **alcançável pelos nós Talos**. Pode ser público ou privado (RFC 1918), desde que haja rota.

### Licença (atenção antes de começar)

- **Talos Linux**: open source (MPL 2.0), uso livre inclusive em produção.
- **Omni**: Business Source License (BSL). **Gratuito apenas para uso não-produtivo** (homelab, lab, dev, testes). Para produção, é necessário contrato com a [Sidero Labs](https://www.siderolabs.com/pricing/).

Este projeto assume **uso em homelab/laboratório**.


## 📁 Estrutura de Diretórios

```
talos-omni-docker-compose/
├── docker-compose.yaml          # Arquivo pai (include das três stacks)
├── .env                         # Variáveis compartilhadas
├── setup-omni.sh                # Script de geração inicial
├── cluster-template.yaml        # Template do cluster Omni
├── manifests/                   # Manifestos do Kubernetes (Omni sync)
│   ├── argocd.yaml
│   └── cilium.yaml
├── patches/                     # Patches de machine config do Talos
│   ├── common/                  # Aplicados a todas as máquinas
│   │   ├── cni.yaml             # Desabilita CNI padrão (para Cilium)
│   │   ├── install.yaml
│   │   ├── kubernetes.yaml
│   │   ├── ntp.yaml
│   │   └── sysctl.yaml
│   ├── controlplane/            # Aplicados apenas ao control plane
│   │   ├── admissioncontrol.yaml
│   │   ├── extra-manifest.yaml
│   │   ├── kubeproxy.yaml
│   │   └── vip.yaml
│   └── worker/                  # Aplicados apenas aos workers
│       └── longhorn-v1.yaml
├── traefik/
│   ├── docker-compose.yaml
│   ├── traefik.yml
│   └── certs/acme.json          # Certificados Let's Encrypt (persistente)
├── dex/
│   ├── docker-compose.yaml
│   └── dex.yaml
└── omni/
    ├── docker-compose.yaml
    ├── config.yaml
    ├── omni.asc                 # Chave GPG para criptografia do etcd
    └── data/
        ├── etcd/                # Dados do etcd embutido
        └── sqlite/              # omni.db
```


## 🚀 Como Usar

### 1. Clonar e configurar

```bash
git clone <repo-url> talos-omni-docker-compose
cd talos-omni-docker-compose
```

Edite o `setup-omni.sh` se quiser ajustar as variáveis padrão (`BASE_DOMAIN`, `OMNI_HOST`, etc.). Por padrão, ele usa `aesthar.com.br`.

### 2. Executar o script de setup

```bash
chmod +x setup-omni.sh
./setup-omni.sh
```

O script:

1. Verifica dependências (`docker`, `gpg`, `openssl`, `curl`).
2. Cria a árvore de diretórios.
3. Solicita interativamente: token do Cloudflare, e-mail e senha do admin, e nome para o EULA.
4. Detecta automaticamente o IP do host via `ip route get 1` (com fallback manual).
5. Gera o hash Bcrypt da senha via container `httpd:2.4-alpine`.
6. Gera a **chave GPG** para criptografia do etcd (`omni/omni.asc`).
7. Gera segredos auxiliares (UUIDs, secret do OIDC).
8. Cria a rede Docker `omni-network`.
9. Escreve todos os arquivos de configuração (`.env`, `docker-compose.yaml`, `traefik.yml`, `dex.yaml`, `config.yaml`, etc.).
10. Valida a stack com `docker compose config -q`.

### 3. Criar os registros DNS

No Cloudflare, crie os registros `A` apontando para o IP do host (sem proxy):

```
omni.<dominio>        → <HOST_PUBLIC_IP>
auth.<dominio>        → <HOST_PUBLIC_IP>
kubernetes.<dominio>  → <HOST_PUBLIC_IP>
siderolink.<dominio>  → <HOST_PUBLIC_IP>
*.omni.<dominio>      → <HOST_PUBLIC_IP>   (opcional, workload proxy)
```

### 4. Subir a stack

```bash
cd omni-stack
docker compose up -d
```

Acompanhe os logs:

```bash
docker compose logs -f omni
docker compose logs -f dex
docker compose logs -f traefik
```

### 5. Primeiro acesso

Acesse `https://omni.<dominio>` no navegador e faça login com o e-mail e senha definidos no setup.

Se você **não** informou o nome para o EULA no script, o Omni redirecionará para `/eula` no primeiro login. Aceite o EULA para liberar o uso.

### 6. Gerar a imagem Talos **pelo Omni** (obrigatório)

> ⚠️ **Não use uma ISO padrão do Talos.** A imagem precisa ser **gerada pelo seu Omni**, pois ele injeta o **join token** e o **endpoint SideroLink** necessários para a máquina se registrar automaticamente. Sem isso, a VM não aparecerá no Omni.

**Via UI**: acesse a seção **Machines** e procure por **Download Installation Media** (ou equivalente na sua versão).

**Via CLI**:

```bash
# Exemplo: gerar uma ISO
omnictl download iso --output talos-omni.iso

# Exemplo: gerar uma imagem para Proxmox/KVM (qcow2)
omnictl download disk --output talos-omni.qcow2 --format qcow2

# Outros formatos: aws, gcp, azure, vmware, metal, etc.
# Consulte: omnictl download --help
```

Formatos disponíveis incluem ISO, imagens para Proxmox/KVM (qcow2/raw), AWS (AMI), GCP, Azure, VMware e bare metal.

**Uso da imagem**:

- **Terraform (provider `dmacvicar/libvirt`)**: aponte o disco da VM para o arquivo gerado (`talos-omni.qcow2` ou similar).
- **Proxmox**: importe a imagem e crie a VM a partir dela.
- **Manual**: dê boot na VM com a ISO.

Ao iniciar, a VM se conectará automaticamente ao Omni via SideroLink e aparecerá em **Machines** como *available*.

> A imagem gerada contém um join token. Se ele vazar, **rotacione-o** em **Machine Management → Join Tokens** e gere uma nova imagem.

### 7. Criar o cluster

Edite o `cluster-template.yaml` para incluir os **UUIDs** das máquinas (obtidos na UI do Omni em **Machines → Copy Machine ID**) e aponte para os patches corretos:

```yaml
kind: Cluster
name: talos-cluster
kubernetes:
  version: v1.37.1
  manifests:
    - name: cilium
      file: ./manifests/cilium.yaml
      mode: one-time
talos:
  version: v1.14.4
features:
  disablePublicDiscoveryService: false
patches:
  - file: ./patches/common/cni.yaml
  - file: ./patches/common/kubernetes.yaml
  - file: ./patches/common/ntp.yaml
  - file: ./patches/common/sysctl.yaml
---
kind: ControlPlane
machines:
  - <UUID-CONTROL-PLANES>
  - <UUID-CONTROL-PLANES>
  - <UUID-CONTROL-PLANES>
patches:
  - file: ./patches/controlplane/admissioncontrol.yaml
  - file: ./patches/controlplane/kubeproxy.yaml
  - file: ./patches/controlplane/vip.yaml
  - file: ./patches/controlplane/extra-manifests.yaml
---
kind: Workers
machines:
  - <UUID-WORKERS>
  - <UUID-WORKERS>
  - <UUID-WORKERS>
patches:
  - file: ./patches/worker/longhorn-v1.yaml

```

Valide e sincronize:

```bash
omnictl cluster template validate -f cluster-template.yaml
omnictl cluster template sync -f cluster-template.yaml --verbose
omnictl cluster template status -f cluster-template.yaml
```


## 🛠️ Instalação das Ferramentas de Cliente

Execute no **host de gerenciamento** (não necessariamente no host do Omni).

### omnictl, talosctl e kubectl

```bash
# omnictl (obtido diretamente do seu Omni)
sudo rm -rf /usr/local/bin/omnictl
curl -LO https://omni.<dominio>/api/omnictl/omnictl-linux-amd64
chmod +x omnictl-linux-amd64
sudo mv omnictl-linux-amd64 /usr/local/bin/omnictl
omnictl completion bash | sudo tee /etc/bash_completion.d/omnictl > /dev/null

# talosctl
sudo rm -rf /usr/local/bin/talosctl
curl -LO https://github.com/siderolabs/talos/releases/download/v1.14.4/talosctl-linux-amd64
chmod +x talosctl-linux-amd64
sudo mv talosctl-linux-amd64 /usr/local/bin/talosctl
talosctl completion bash | sudo tee /etc/bash_completion.d/talosctl > /dev/null

# kubectl
sudo rm -rf /usr/local/bin/kubectl
curl -LO https://dl.k8s.io/release/v1.37.0/bin/linux/amd64/kubectl
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null

source ~/.bashrc
```

### Krew + oidc-login

O plugin `oidc-login` é **obrigatório** para autenticar no Kubernetes via OIDC.

```bash
(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew
)

echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

kubectl krew install oidc-login
```

### Helm (opcional)

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh
helm completion bash | sudo tee /etc/bash_completion.d/helm > /dev/null
```


## 🔑 Acessar o Cluster

```bash
# kubeconfig (com autenticação OIDC via navegador ou teclado)
omnictl kubeconfig --cluster talos-cluster --grant-type=authcode-keyboard

# talosconfig
omnictl talosconfig --cluster talos-cluster

# Verificar
kubectl get nodes -o wide
```

Na primeira execução, o `oidc-login` abrirá o navegador (ou imprimirá uma URL/código no modo teclado) para autenticar via Dex.


## 🔧 Operação

### Variáveis de ambiente principais (`.env`)

| Variável | Descrição |
| :--- | :--- |
| `BASE_DOMAIN` | Domínio base (ex: `aesthar.com.br`) |
| `OMNI_HOST` | Hostname do Omni |
| `AUTH_HOST` | Hostname do Dex |
| `HOST_PUBLIC_IP` | IP usado no `advertisedEndpoint` do WireGuard |
| `CF_DNS_API_TOKEN` | Token Cloudflare para DNS-01 |
| `OMNI_USER_EMAIL` | E-mail do admin inicial |
| `OMNI_USER_PASSWORD_HASH` | Hash Bcrypt da senha do admin |
| `OMNI_DEX_SECRET` | Secret OIDC entre Omni e Dex |
| `OMNI_VERSION` | Versão da imagem do Omni |
| `TRAEFIK_VERSION` | Versão do Traefik |
| `DEX_VERSION` | Versão do Dex |

### Backup

**Crítico**: guarde `omni/omni.asc` em local seguro. Sem essa chave, os dados do etcd **não podem ser recuperados**.

```bash
# Backup completo
tar czf omni-backup-$(date +%Y%m%d).tar.gz \
  omni/data \
  omni/omni.asc \
  omni/config.yaml \
  dex/dex.yaml \
  .env \
  cluster-template.yaml \
  patches/ \
  manifests/
```

O **etcd embutido** é persistido em `omni/data/etcd/`. Como o Omni se conecta a ele em memória (não escuta em rede a partir de versões recentes), o backup deve ser feito via snapshot do etcd ou pela própria ferramenta do Omni, não por `etcdctl` direto.

### Logs

```bash
docker compose logs -f omni
docker compose logs -f dex
docker compose logs -f traefik
```

### Atualização de versões

Edite `TRAEFIK_VERSION`, `DEX_VERSION` e `OMNI_VERSION` no `.env`, depois:

```bash
docker compose pull
docker compose up -d
```

### Troubleshooting comum

**`error: unknown command "oidc-login" for "kubectl"`**

O plugin não está instalado. Siga a seção [Krew + oidc-login](#krew--oidc-login).

**Certificado expirado ou inválido**

O Traefik renova automaticamente via ACME. Se houver problemas, verifique `traefik/certs/acme.json` e os logs do Traefik. Como a renovação é feita via DNS-01, o token do Cloudflare precisa permanecer válido.

**Nós Talos não se conectam ao Omni**

Verifique:
1. Se a VM foi criada a partir de uma **imagem gerada pelo Omni** (não de uma ISO padrão do Talos).
2. Se o `advertisedEndpoint` do WireGuard no `omni/config.yaml` está correto e alcançável pelos nós.
3. Se a porta `50180/UDP` está aberta no firewall do host.
4. Se o join token usado na imagem/cloud-init é válido.

**Cluster stuck em `Provisioning`**

Verifique os patches de machine config. Um patch de rede mal formado pode impedir o nó de se conectar. A partir do Talos 1.14, o Omni aplica patches em "try mode" — se o nó perder a conexão, o patch é revertido automaticamente.


## 🔐 Segurança

- **Rotacione join tokens** periodicamente e sempre que um token for exposto. Na UI: **Machine Management → Join Tokens**. Lembre-se: as imagens geradas pelo Omni contêm um join token embutido.
- **`omni.asc`** é a chave que criptografa o etcd. Trate-a como segredo de produção.
- **Token do Cloudflare**: use um token com escopo mínimo (`Zone:DNS:Edit` apenas para a zona necessária).
- **Socket do Docker**: o container do Traefik monta `/var/run/docker.sock` em modo read-only. Isso é necessário para o provider Docker do Traefik, mas representa um risco se o container for comprometido.
- **TLS**: os certificados são emitidos publicamente via Let's Encrypt. Não há CA interna, então o tráfego entre Traefik e Omni/Dex é HTTP/h2c **dentro da rede Docker**. Para produção, considere mTLS ou rede isolada.


## 🧭 Decisões de Design

| Decisão | Motivo |
| :--- | :--- |
| **Traefik como terminação TLS** | Elimina a necessidade de certificados internos no Omni e Dex. O Omni serve h2c e o Traefik faz o TLS. |
| **Dex em vez de Auth0/SAML** | Autenticação local, sem dependência de provedores externos. Ideal para lab. |
| **etcd embutido** | Simplicidade. Para HA, use etcd externo. |
| **WireGuard direto (UDP 50180)** | O Traefik não faz proxy UDP, então o Omni publica essa porta diretamente. |
| **Cilium via Omni manifest sync** | Recomendação oficial da Sidero para clusters gerenciados pelo Omni. |
| **Terraform para provisionar VMs** | Mantém a infraestrutura como código. O Omni apenas descobre as máquinas via SideroLink. |
| **Imagem gerada pelo Omni** | Garante que o join token e o endpoint SideroLink estejam embutidos, permitindo o registro automático das VMs. |

---

## 📚 Referências

- [Run Omni On-Prem](https://docs.siderolabs.com/omni/self-hosted/run-omni-on-prem)
- [Omni Configuration Reference](https://docs.siderolabs.com/omni/reference/omni-configuration)
- [Cluster Templates](https://docs.siderolabs.com/omni/reference/cluster-templates)
- [Deploying Cilium](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)
- [Deploy Argo CD](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/deploy-argocd)
- [kenlasko/omni](https://github.com/kenlasko/omni) — referência de arquitetura de portas
- [Sidero Labs Blog — TalosCon Amsterdam 2026](https://www.siderolabs.com/blog/taloscon-amsterdam-2026-recap-the-community-in-one-room)


## 📄 Licença

### Este projeto (configuração, scripts e templates)

Todo o conteúdo deste repositório — incluindo `docker-compose.yaml`, `setup-omni.sh`, `cluster-template.yaml`, os arquivos em `patches/` e `manifests/`, bem como esta documentação — é de autoria do mantenedor e está licenciado sob a **[MIT License](https://opensource.org/licenses/MIT)**. Uso livre, modificação e redistribuição sem restrições.

### Sidero Omni e Talos Linux

- **Talos Linux**: open source sob [MPL 2.0](https://github.com/siderolabs/talos/blob/main/LICENSE). Uso livre, inclusive em produção.
- **Omni**: licenciado sob [Business Source License (BSL)](https://github.com/siderolabs/omni/blob/main/LICENSE). A BSL permite uso **gratuito apenas em ambientes não-produtivos** — homelab, laboratório, desenvolvimento e testes. **Uso em produção requer um contrato de suporte com a [Sidero Labs](https://www.siderolabs.com/pricing/)**.

Este repositório é voltado explicitamente para **homelab e laboratório**, cenário coberto pela licença BSL sem custo. Se você pretende usar o Omni em produção, entre em contato com a Sidero Labs para licenciamento comercial.