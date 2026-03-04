# Instalacion de RK2 con Cilium
Para instalar **RKE2** con **Cilium** y un Ingress controller, el proceso se divide en dos fases principales: prepararacion del nodo e instalacion de componentes.

## 1. Preparación de Nodos (Ubuntu Server) para RKE2, Cilium y Rook-Ceph
Esta fase configura el sistema operativo base para cumplir con los requisitos del perfil CIS de RKE2, prepara el entorno para el enrutamiento eBPF puro de Cilium y deja listos los prerrequisitos de almacenamiento en bloque para Rook-Ceph.
Ejecutar los siguientes pasos como `root` en **todos los nodos** del clúster:

### Paso 1.1 Actualización del Sistema y Desactivación de Swap
Kubernetes requiere que la memoria swap esté completamente deshabilitada para una correcta asignación de recursos del kubelet.

```bash
# Actualizar paquetes del sistema
apt update && apt upgrade -y

# Deshabilitar swap en caliente
swapoff -a

# Comentar la línea de swap en fstab para persistencia tras reinicios
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### Paso 1.2. Instalación de Dependencias Críticas
Se requieren herramientas específicas para la gestión de tráfico, eBPF y la administración de volúmenes lógicos y cifrado. En Ubuntu, los nombres de algunos paquetes cambian (como `open-iscsi` en lugar de `iscsi-initiator-utils` y `iproute2` en lugar de `iproute-tc`).

```bash
# Instalar utilidades requeridas
apt install -y tar curl iptables iproute2 lvm2 open-iscsi cryptsetup

# Habilitar el demonio iSCSI (Rook-Ceph lo requiere activo en Ubuntu)
systemctl enable --now iscsid
```

### Paso 1.3. Carga de Módulos del Kernel
Habilitamos los módulos necesarios para la superposición de contenedores, la encriptación de red nativa y el almacenamiento en bloque.

```bash
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
wireguard
rbd
ceph
EOF

# Cargar módulos en la sesión actual
modprobe overlay
modprobe wireguard
modprobe rbd
modprobe ceph
```

### Paso 1.4. Ajustes de Kernel (Sysctl)

Aplicamos los parámetros requeridos para el reenvío de paquetes, optimización del compilador JIT para eBPF (Tetragon/Cilium), cumplimiento estricto del perfil CIS y aumento de límites de inotify para el rendimiento del almacenamiento masivo.

```bash
cat <<EOF > /etc/sysctl.d/99-k8s-cis.conf
# Enrutamiento de red para Kubernetes y Cilium
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1

# Optimizaciones para eBPF (Cilium / Tetragon)
net.core.bpf_jit_enable             = 1

# Requerimientos estrictos del perfil CIS para RKE2
vm.panic_on_oom                     = 0
vm.overcommit_memory                = 1
kernel.panic                        = 10
kernel.panic_on_oops                = 1

# Aumentar límites inotify (vital para Rook-Ceph y bases de datos)
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
EOF

# Aplicar los cambios
sysctl --system
```

### 1.5. Preparación de Red y Firewall
A diferencia de Rocky Linux, Ubuntu Server utiliza `systemd-networkd` (mediante Netplan) por defecto, el cual no interfiere automáticamente con las interfaces virtuales de Cilium. Sin embargo, debemos asegurarnos de desactivar el firewall nativo (UFW) para evitar colisiones con las reglas de red que Cilium gestionará de forma autónoma.

```bash
# Deshabilitar y detener UFW para que Cilium controle el tráfico
ufw disable
systemctl stop ufw
systemctl disable ufw
```

### 1.6. Verificación de Discos (Rook-Ceph)
Rook-Ceph requiere discos crudos (*raw disks*) sin formato ni particiones. Confirma la disponibilidad de los bloques de almacenamiento con el siguiente comando:

```bash
lsblk -f
```

## 2. Configuración Previa del Control Plane (RKE2)
En esta fase, prepararemos el entorno base del sistema operativo y la configuración declarativa para RKE2 en Ubuntu. Esto incluye la creación manual del usuario de servicio para la base de datos y la definición del archivo principal de configuración (`config.yaml`) para cumplir con el estándar CIS y delegar la red a Cilium.
Ejecutar los siguientes pasos como `root` en el nodo destinado a ser el primer **Control Plane** (`master-0`):

### 2.1. Creación del usuario y grupo de base de datos (`etcd`)
Para cumplir con el perfil CIS (los procesos de base de datos no deben correr como `root`), creamos preventivamente el usuario de servicio estricto. Esto evita que el servicio falle al intentar arrancar por primera vez.

```bash
# Crear el grupo del sistema
groupadd -r etcd

# Crear el usuario asignado a ese grupo sin acceso a shell ni directorio home
useradd -r -M -g etcd -s /usr/sbin/nologin -c "RKE2 etcd user" etcd
```

*(Nota: En Ubuntu, la ruta correcta para nologin suele ser `/usr/sbin/nologin` en lugar de `/sbin/nologin`).*

### Paso 2.2. Creación de la Estructura de Directorios
Preparamos las rutas donde RKE2 buscará su configuración declarativa antes de iniciar el binario.

```bash
mkdir -p /etc/rancher/rke2/
```

### Paso 2.3. Definición de la Política de Auditoría (Requisito CIS)
El perfil CIS exige que el API Server registre eventos críticos. Esta política registra la metadata de las peticiones, excluyendo el ruido generado por los componentes internos del sistema para optimizar el uso de CPU y disco.

```bash
cat <<EOF > /etc/rancher/rke2/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # No registrar eventos de lectura/lista (genera demasiado ruido)
  - level: None
    verbs: ["get", "watch", "list"]
  # Registrar cambios en Secretos y ConfigMaps a nivel de Metadata (por seguridad)
  - level: Metadata
    resources:
    - group: ""
      resources: ["secrets", "configmaps"]
  # Registrar cambios en el resto a nivel de RequestResponse
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
EOF
```

### 2.4. Creación del Manifiesto Principal (`config.yaml`)
Este archivo define la identidad y la postura de seguridad del clúster. Destacan el cumplimiento del CIS Benchmark, la encriptación de secretos en etcd y la desactivación del CNI por defecto (`rke2-canal`) y de `kube-proxy` para ceder el control del enrutamiento a Cilium eBPF.

```bash
cat <<EOF > /etc/rancher/rke2/config.yaml
# --- Seguridad Base ---
cni: "none"
profile: "cis"
disable:
- rke2-ingress-nginx
disable-kube-proxy: true

kubelet-arg:
  - "anonymous-auth=false"
  - "authorization-mode=Webhook"
  - "protect-kernel-defaults=true"

kube-apiserver-arg:
  - "audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log"
  - "audit-policy-file=/etc/rancher/rke2/audit-policy.yaml"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
  - "profiling=false"
  - "anonymous-auth=false"
EOF
```

## 3. Instalación y Arranque del Control Plane (RKE2)
En este punto, RKE2 consumirá el `config.yaml` de la Fase 2, aplicará el perfil de seguridad CIS y levantará los servicios base.
Ejecuta los siguientes pasos como `root` en tu nodo **`master-0`**:

### 3.1. Descarga e Instalación del Binario
Utilizaremos el script oficial. Al detectar que estás en Ubuntu, el script instalará el paquete `.deb` correspondiente y configurará los servicios de `systemd`.

```bash
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="server" sh -
```

### 3.2. Habilitar e Iniciar el Servicio
Este es el paso donde RKE2 descarga las imágenes de sistema (v1.34.3) y genera los certificados. Ten paciencia, puede tardar de **3 a 5 minutos**.

```bash
systemctl enable rke2-server.service
systemctl start rke2-server.service
```

**Tip de monitoreo:** Tal como hicimos antes, puedes ver el progreso real y detectar cualquier bloqueo de permisos con:
`journalctl -u rke2-server -f`

### 3.3. Configuración del Entorno (`kubectl`)
RKE2 coloca sus binarios en `/var/lib/rancher/rke2/bin/`. Vamos a configurar tu acceso para que `kubectl` funcione directamente.

```bash
# Crear el directorio de configuración
mkdir -p ~/.kube

# Vincular el kubeconfig generado (con permisos 0600 automáticos)
cp /etc/rancher/rke2/rke2.yaml ~/.kube/config

# Configurar el PATH para que reconozca los binarios de RKE2
export PATH=$PATH:/var/lib/rancher/rke2/bin
echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> ~/.bashrc
```

### 3.4. Verificación del Estado de Salud
Ahora validaremos que el clúster esté vivo pero "esperando" su red (Cilium).

```bash
# Deberías ver el nodo master-0 como "NotReady" (normal sin CNI)
kubectl get nodes

# Deberías ver los componentes core (etcd, apiserver) levantados
kubectl get pods -A
```

## 4. Instalación de Cilium CNI mediante CLI (Modo eBPF Nativo)
En esta fase, instalaremos la herramienta de línea de comandos de Cilium y desplegaremos el agente en el clúster. Al usar RKE2 con el perfil CIS, Cilium se encargará de gestionar las políticas de red y el reemplazo de `kube-proxy`.

### 4.1. Instalar el Cilium CLI en el Master
Primero, descargamos el binario de gestión de Cilium directamente en tu nodo `master-0`.

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
tar xzvf cilium-linux-${CLI_ARCH}.tar.gz
sudo install -m 0755 cilium /usr/local/bin/cilium
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

### 4.2. Desplegar Cilium en el Clúster

Ahora ejecutamos la instalación. Es vital especificar que estamos en RKE2 y que queremos habilitar el reemplazo de `kube-proxy`.

```bash
cilium install
```

### Paso 4.3. Verificar la Instalación
Cilium tardará un par de minutos en levantar sus pods. Puedes monitorear el estado con:

```bash
# Verificar el estado desde la CLI de Cilium
cilium status --wait

   /¯¯\
/¯¯\__/¯¯\    Cilium:         OK
\__/¯¯\__/    Operator:       OK
/¯¯\__/¯¯\    Hubble:         disabled
\__/¯¯\__/    ClusterMesh:    disabled
   \__/

DaemonSet         cilium             Desired: 2, Ready: 2/2, Available: 2/2
Deployment        cilium-operator    Desired: 2, Ready: 2/2, Available: 2/2
Containers:       cilium-operator    Running: 2
                  cilium             Running: 2
Image versions    cilium             quay.io/cilium/cilium:v1.9.5: 2
                  cilium-operator    quay.io/cilium/operator-generic:v1.9.5: 2
```

```bash
# Verificar que los nodos pasen a estado "Ready"
kubectl get nodes
```

### Paso 4.4. Validar el Enrutamiento eBPF
Para confirmar que Cilium está gestionando el tráfico sin depender de iptables heredadas, ejecuta:

```bash
kubectl exec -it -n kube-system ds/cilium -- cilium status --verbose | grep "KubeProxyReplacement"
```

## 5. Unión de Nodos Worker (RKE2 Agents)
En esta fase, configuraremos los nodos secundarios para que se unan al Control Plane. Al usar el perfil CIS, RKE2 se encargará de configurar el `kubelet` de los workers con el mismo nivel de seguridad que el Master.

### 5.1. Obtener el Token del Master
Ejecuta este comando **solo en el nodo `master-0**` para obtener la clave secreta de unión:

```bash
cat /var/lib/rancher/rke2/server/node-token
```

### 5.2. Configurar los Workers (`worker-0` y `worker-1`)
En **cada nodo worker**, prepara el directorio y el archivo de configuración. Asegúrate de usar la IP del Master y el token que acabas de copiar.

```bash
mkdir -p /etc/rancher/rke2/

cat <<EOF > /etc/rancher/rke2/config.yaml
server: https://<TU_NODE_IP_AQUÍ>:9345
token: <TU_NODE_TOKEN_AQUÍ>
profile: "cis"
cni: "none"
disable-kube-proxy: true

kubelet-arg:
  - "anonymous-auth=false"
  - "authorization-mode=Webhook"
EOF
```

### 5.3. Instalación del Binario de Agente
En **cada nodo worker**, ejecuta el instalador especificando que el tipo es `agent`:

```bash
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -
```

### 5.4. Habilitar e Iniciar el Servicio
Al igual que con el Master, el primer arranque configurará los certificados locales del worker.

```bash
systemctl enable rke2-agent.service
systemctl start rke2-agent.service
```

### 5.5. Verificación Final
Vuelve a tu nodo **`master-0`** y verifica que los nuevos nodos aparezcan y que Cilium les asigne una red automáticamente.

```bash
kubectl get nodes -o wide
```

## 6. Alta Disponibilidad - Añadir Masters Adicionales (Servers)
En esta fase, extenderemos el plano de control a un segundo o tercer nodo. Cada nodo Master adicional ejecutará una réplica de `etcd` y del `kube-apiserver`.

### 6.1. Obtener el Token (Si no lo tienes)
Al igual que con los workers, necesitas el token del primer nodo (`master-0`):

```bash
cat /var/lib/rancher/rke2/server/node-token
```

### 6.2. Configurar el nuevo Master (`master-1`)
En el nuevo nodo, prepara el archivo de configuración. Es vital que el perfil CIS sea idéntico al del primer nodo.

```bash
mkdir -p /etc/rancher/rke2/

cat <<EOF > /etc/rancher/rke2/config.yaml
server: https://<TU_NODE_MASTER_IP_AQUÍ>:9345
token: <TU_NODE_TOKEN_AQUÍ>
profile: "cis"

cni: "none"
disable-kube-proxy: true

kubelet-arg:
  - "anonymous-auth=false"
  - "authorization-mode=Webhook"
  - "protect-kernel-defaults=true"

kube-apiserver-arg:
  - "audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log"
  - "audit-policy-file=/etc/rancher/rke2/audit-policy.yaml"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
  - "profiling=false"
  - "anonymous-auth=false"
EOF
```

### Paso 6.4. Definición de la Política de Auditoría (Requisito CIS)
El perfil CIS exige que el API Server registre eventos críticos. Esta política registra la metadata de las peticiones, excluyendo el ruido generado por los componentes internos del sistema para optimizar el uso de CPU y disco.

```bash
cat <<EOF > /etc/rancher/rke2/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # No registrar eventos de lectura/lista (genera demasiado ruido)
  - level: None
    verbs: ["get", "watch", "list"]
  # Registrar cambios en Secretos y ConfigMaps a nivel de Metadata (por seguridad)
  - level: Metadata
    resources:
    - group: ""
      resources: ["secrets", "configmaps"]
  # Registrar cambios en el resto a nivel de RequestResponse
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
EOF
```

### 6.5. Preparar el usuario `etcd`
Como activamos el perfil CIS, el nuevo Master también intentará ejecutar la base de datos con el usuario dedicado. **Debes crearlo antes de iniciar el servicio** para evitar el error que tuvimos anteriormente.

```bash
groupadd -r etcd
useradd -r -M -g etcd -s /usr/sbin/nologin -c "RKE2 etcd user" etcd
```

### 6.6. Instalación y Arranque

Instala el binario de tipo `server` (no `agent`) en el nuevo nodo:

```bash
# Instalar binario tipo server
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="server" sh -

# Habilitar e iniciar
systemctl enable rke2-server.service
systemctl start rke2-server.service
```

### 6.7. Verificación de la Base de Datos (etcd)
Una vez que el servicio inicie, verifica desde cualquier Master que el nuevo nodo se haya unido al quórum de la base de datos:

```bash
kubectl get nodes
# Para ver el estado de salud de etcd:
kubectl get pods -n kube-system -l component=etcd
```
