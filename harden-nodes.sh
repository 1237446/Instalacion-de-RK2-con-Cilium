#!/bin/bash

echo "Iniciando ajuste de permisos universal para RKE2..."

# 1. Directorio de configuración del Kubelet
if [ -d "/var/lib/rancher/rke2/agent/etc/kubelet.conf.d" ]; then
    echo "[+] Ajustando permisos en kubelet.conf.d a 600..."
    sudo chmod 600 /var/lib/rancher/rke2/agent/etc/kubelet.conf.d
fi

# 2. Archivos kubeconfig
echo "[+] Asegurando propiedad root:root en archivos .kubeconfig..."
sudo find /var/lib/rancher/rke2/agent -name "*.kubeconfig" -exec chown root:root {} \;
sudo find /var/lib/rancher/rke2/agent -name "*.kubeconfig" -exec chmod 600 {} \;

# 3. Certificados (Ruta dinámica para Server o Agent)
echo "[+] Buscando y asegurando certificados..."
# Busca en la ruta de Agent y en la de Server por si acaso
CERT_PATHS=("/var/lib/rancher/rke2/agent/pki" "/var/lib/rancher/rke2/server/pki")

for path in "${CERT_PATHS[@]}"; do
    if [ -d "$path" ]; then
        echo "[+] Protegiendo certificados en: $path"
        sudo find "$path" -type f \( -name "*.crt" -o -name "*.key" \) -exec chmod 600 {} \;
        sudo find "$path" -type f \( -name "*.crt" -o -name "*.key" \) -exec chown root:root {} \;
    fi
done

echo "Ajuste completado con éxito."
