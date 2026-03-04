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
  # Omitir eventos de solo lectura de componentes internos del sistema
  - level: None
    users: ["system:kube-proxy", "system:apiserver", "system:kubelet"]
    verbs: ["get", "watch", "list"]
  # Registrar a nivel de Metadata todas las demás peticiones
  - level: Metadata
    omitStages:
      - "RequestReceived"
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

*Nota: La IP `172.16.9.131` corresponde a tu Master detectada en los logs previos.*

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



















## Nodo Mestro

### Paso 1: Preparación del Nodo

*  **Crea el archivo de configuración de RKE2**: Antes de instalar RKE2, necesitas decirle que no use sus componentes predeterminados. Para ello, crea un directorio y un archivo de configuración.

    ```sh
    sudo mkdir -p /etc/rancher/rke2/
    sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
    cni: "none"
    disable:
    - rke2-ingress-nginx
    disable-kube-proxy: true
    EOF
    ```

      * `cni: "none"`: Le dice a RKE2 que no instale ningún CNI por defecto.
      * `disable: - rke2-ingress-nginx`: Desactiva el controlador NGINX Ingress que viene incluido con RKE2.
      * `disable-kube-proxy: true`: Deshabilita el `kube-proxy` de Kubernetes, ya que Cilium se encargará de esta función.

*  **Instala RKE2 Server:**
    Una vez que el script finalice, se instalarán los servicios necesarios.
    ```sh
    curl -sfL https://get.rke2.io | sudo sh -
    ```

*  **Habilitar e iniciar el servicio de RKE2:**
    ```sh
    sudo systemctl enable --now rke2-server.service
    ```

> [\!NOTE]
> En este punto, el clúster estará en funcionamiento, pero los nodos estarán en estado `NotReady` porque aún no tienen un CNI.

-----

### Paso 2: Instalación de Cilium e Ingress

#### Configurar acceso a `kubectl`

Para interactuar con el clúster, configura el `kubeconfig`:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
export KUBECONFIG=~/.kube/config
```

#### Instalar Cilium con CLI

Cilium se instalará utilizando su CLI oficial para garantizar la mejor configuración.

*  **Instalar Cilium CLI:**
    ```bash
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
    
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
    sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
    rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    ```

*  **Desplegar Cilium en el clúster:**
    ```bash
    cilium install
    ```

*  **Validar la instalación:**
    Verifica que todos los componentes estén sanos:
    ```bash
    cilium status --wait
    ```
    ```sh
    $ cilium status --wait
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

#### Instalar NGINX Ingress Controller

Como desactivamos el Ingress por defecto de RKE2, instalaremos la versión mantenida por la comunidad (o Kubernetes) vía Helm.

*  **Añadir repositorio e instalar:**
    ```bash
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    
    helm install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx \
      --create-namespace   
    ```

*  **Verificar el despliegue:**
    ```bash
    kubectl get pods -n ingress-nginx
    ```

## 2. Nodos Trabajadores (Agents)

Para agregar dos nodos (esclavo) más a tu clúster **RKE2** existente, debes generar un token de unión y luego usarlo para unir los nuevos nodos como agentes.

### Paso 1: Obtener el token del servidor

Para agregar capacidad de cómputo, uniremos nodos adicionales en modo Agente.

```bash
sudo cat /var/lib/rancher/rke2/server/node-token
```

### Paso 2: Configurar y Unir el Nuevo Nodo

En cada uno de los dos nuevos nodos, debes crear un archivo de configuración para RKE2. Este archivo le dirá al nodo que se una al clúster como un agente y también le indicará que debe usar Cilium como CNI, al igual que el servidor.

*  **Crea el directorio y el archivo de configuración**:

    ```sh
    sudo mkdir -p /etc/rancher/rke2/
    sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
    server: https://<DIRECCIÓN_IP_DEL_SERVIDOR>:9345
    token: <TU_TOKEN_OBTENIDO_ARRIBA>
    cni: "none"
    disable-kube-proxy: true
    EOF
    ```

      * **`<DIRECCIÓN_IP_DEL_SERVIDOR>`**: Reemplaza esto con la dirección IP del nodo donde instalaste RKE2 como servidor.
      * **`<TU_TOKEN_OBTENIDO_ARRIBA>`**: Reemplaza esto con el token que obtuviste en el paso anterior.
      * `cni: "none"` y `disable-kube-proxy: true`: Estas líneas son cruciales para asegurar que los nuevos nodos utilicen la misma configuración de red que el servidor principal.

> [\!IMPORTANT]
> Es crucial mantener `cni: "none"` y `disable-kube-proxy: true` para que la red coincida con la configuración del maestro.

*  **Instalar RKE2 en modo Agente:**
    ```bash
    curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE="agent" sh -
    ```

*  **Iniciar el servicio:**
    ```bash
    sudo systemctl enable --now rke2-agent.service
    ```

> [\!NOTE]
> Después de un minuto o dos, los nodos se conectarán al servidor, Cilium se desplegará en ellos y se unirán al clúster.

### Paso 3: Verificar la unión de los nodos

Vuelve al nodo servidor y ejecuta el siguiente comando para ver el estado de los nodos del clúster:

```sh
kubectl get nodes
```

> [\!NOTE]
> Deberías ver los tres nodos (el servidor y los dos nuevos agentes) en estado **`Ready`**.

## 3. Añadir Nodo Maestro (Alta Disponibilidad)

Para añadir un **nodo maestro** adicional a un clúster **RKE2** existente, debes instalar el servicio `rke2-server` en el nuevo nodo, apuntándolo al servidor inicial y utilizando el mismo token. Esto crea un clúster de **alta disponibilidad (HA)**.

### Paso 1: Preparación del Nuevo Servidor Maestro

De manera similar al primer nodo maestro, necesitas configurar el nuevo nodo maestro para que sepa cómo unirse al clúster y qué componentes deshabilitar.

*  **Crea el Archivo de Configuración:**
    Crea el directorio y el archivo de configuración en el **nuevo servidor maestro**.

    ```bash
    sudo mkdir -p /etc/rancher/rke2/
    sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
    server: https://<IP_DEL_SERVIDOR_INICIAL>:9345
    token: <TU_TOKEN_OBTENIDO>
    cni: "none"
    disable:
    - rke2-ingress-nginx
    disable-kube-proxy: true
    EOF
    ```

      * **`<IP_DEL_SERVIDOR_INICIAL>:9345`**: Esta línea es **crucial**. Le dice al nuevo servidor que se una al plano de control existente a través de la IP del primer nodo maestro. El puerto por defecto es `9345`.
      * **`<TU_TOKEN_OBTENIDO>`**: Usa el token que obtuviste del servidor inicial.
      * Las opciones de `cni: "none"` y `disable-kube-proxy: true` son necesarias para mantener la coherencia con el primer servidor, que usa Cilium y deshabilitó el `kube-proxy`.

> [\!TIP]
> El token que usaste o generaste previamente, se puede ver con `cat /var/lib/rancher/rke2/server/node-token` en el servidor inicial.

### Paso 2: Instalación y Arranque

*  **Instalar RKE2 (Modo Server por defecto):**
    No especificamos el tipo "agent", por lo que se instala como Server.
    ```bash
    curl -sfL https://get.rke2.io | sudo sh -
    ```


*  **Iniciar servicio:**
    ```bash
    sudo systemctl enable --now rke2-server.service
    ```

### Paso 3: Validación Final

En cualquier nodo con acceso a `kubectl`, verifica que el nuevo nodo tenga el rol de `control-plane` y `master`:

```bash
kubectl get nodes
```

> [\!NOTE]
>Deberías ver el nuevo nodo con el rol **`control-plane`** o **`master`** (y quizás también `etcd`), y su estado eventualmente cambiará a **`Ready`** a medida que Cilium se despliegue en él y se sincronice con el plano de control. El plano de control de tu clúster RKE2 ahora será de **alta disponibilidad**.
