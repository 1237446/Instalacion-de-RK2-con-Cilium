# Instalacion de RK2 con Cilium

Para instalar **RKE2** con **Cilium** y un Ingress controller, el proceso se divide en dos fases principales: prepararacion del nodo e instalacion de componentes.

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
