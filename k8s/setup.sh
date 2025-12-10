git clone https://github.com/omartamer630/setup-configuration/k8s

cd k8s

kind create cluster \
    --config kind-config.yml

kubectl get nodes

kubectl apply \
    --filename https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml
    
kubectl apply -f ingress.yml
