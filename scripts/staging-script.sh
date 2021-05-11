#!/usr/bin/env bash


environment () {
  HELMPATH=$(which helm)
  if [ "${HELMPATH}" == "" ]; then
    echo "You must have helm installed and have done a 'helm init' to run this script."
    exit 1
  fi

  # Set values that will be overwritten if env.sh exists
  echo "Setting up the environment..."
  export DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  export REGION='us-central1'
  export ZONE='us-central1-f'
  export CLUSTER_NAME='gitlab-cluster'
  export PROJECT_ID=$(gcloud config get-value project)
  export PROJECT_NUMBER=$(gcloud projects list --filter="${PROJECT_ID}" --format="value(PROJECT_NUMBER)")

  [[ -f "${DIR}/env.sh" ]] && echo "Importing environment from ${DIR}/env.sh..." && . ${DIR}/env.sh
  echo "Writing ${DIR}/env.sh..."
  cat >> ${DIR}/env.sh << EOF
export REGION=${REGION}
export ZONE=${ZONE}
export CLUSTER_NAME=${CLUSTER_NAME}
export PROJECT_ID=${PROJECT_ID}
export PROJECT_NUMBER=${PROJECT_NUMBER}
EOF
}



gke_setup () {

  set +x; echo "Enabling APIs..."
  set -x
  gcloud services enable iam.googleapis.com
  gcloud services enable compute.googleapis.com
  gcloud services enable containerregistry.googleapis.com
  gcloud services enable artifactregistry.googleapis.com
  gcloud services enable container.googleapis.com
  gcloud services enable run.googleapis.com
  gcloud services enable cloudbuild.googleapis.com
  gcloud services enable datastore.googleapis.com
  gcloud services enable firestore.googleapis.com

  set +x; echo; set -x

  set +x; echo "Creating gitlab cluster..."
  set -x
  gcloud container clusters create gitlab-cluster \
      --zone ${ZONE} \
      --release-channel=regular --cluster-version 1.18 \
      --machine-type n1-standard-4 \
      --scopes cloud-platform \
      --num-nodes 3\
      --enable-ip-alias \
      --project ${PROJECT_ID}
  set +x; echo

  echo "Waiting for cluster bring up..."
  sleep 45

    # Connect to cluster
  set +x; echo "Connect to cluster.."
  set -x;
  gcloud container clusters get-credentials gitlab-cluster --zone ${ZONE} --project ${PROJECT_ID}
  set +x; echo


  #export PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password -ojsonpath='{.data.password}' | base64 --decode ; echo)



  #Install Nginx Ingress
  set +x; echo "Install NGINX Ingress.."
  set -x
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v0.45.0/deploy/static/provider/cloud/deploy.yaml
  set +x; echo



  set +x; echo "Set up bindings.."
  set -x
  kubectl create clusterrolebinding cluster-admin-binding \
  --clusterrole=cluster-admin \
  --user=$(gcloud config get-value core/account)
  #Give your compute service account IAM access to Secret Manager
  gcloud projects add-iam-policy-binding ${PROJECT_ID} --member serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com --role roles/secretmanager.admin

}




gcp_bindings () {
# Grant the Cloud Run Admin role to the Cloud Build service account
set +x; echo "Setting IAM Binding for Cloud Build and Cloud Run.."

set -x
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role roles/cloudbuild.builds.editor
set +x; echo

# Grant the IAM Service Account User role to the Cloud Build service account on the Cloud Run runtime service account
set -x
gcloud iam service-accounts add-iam-policy-binding \
  ${PROJECT_NUMBER}-compute@developer.gserviceaccount.com \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
set +x; echo

# Grant the Cloud Run Admin role to the compute service account

set -x
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role roles/run.admin
set +x; echo

# Grant the IAM Service Account User role to the Compute service account on the Cloud Run runtime service account
set -x
gcloud iam service-accounts add-iam-policy-binding \
  ${PROJECT_NUMBER}-compute@developer.gserviceaccount.com \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
set +x; echo

# Grant the Cloud Run Admin role to the Cloud Build service account
set -x
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member "serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role roles/run.admin
set +x; echo

# Grant the IAM Service Account User role to the Cloud Build service account on the Cloud Run runtime service account
set -x
gcloud iam service-accounts add-iam-policy-binding \
  ${PROJECT_NUMBER}-compute@developer.gserviceaccount.com \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
set +x; echo
}




tekton () {

    set +x; echo "Connect to cluster..."
    set -x;
    gcloud container clusters get-credentials gitlab-cluster --zone ${ZONE} --project ${PROJECT_ID}
    set +x; echo

    # Install Tekton Pipelines
    set +x; echo "Install Tekton Pipelines v0.230..."
    set -x
    kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/previous/v0.23.0/release.yaml
    set +x; echo

    # Install Tekton Triggers
    set +x; echo "Install Tekton Triggers v0.13.0..."
    set -x
    kubectl apply -f https://github.com/tektoncd/triggers/releases/download/v0.13.0/release.yaml
    kubectl apply -f https://github.com/tektoncd/triggers/releases/download/v0.13.0/interceptors.yaml
    set +x; echo

    # Install Tekton Dashboard
    set +x; echo "Install Tekton Dashboard v0.16.0..."
    set -x
    kubectl apply --filename https://github.com/tektoncd/dashboard/releases/download/v0.16.0/tekton-dashboard-release.yaml
    set +x; echo

    sed -i "s/TEKTON_DOMAIN/${TEKTON_DOMAIN}/g" tekton/gitlab-base/gitlab-ingress.yaml
    sed -i "s/TEKTON_DOMAIN/${TEKTON_DOMAIN}/g" tekton/resources/dashboard-ing.yaml

    sleep 30


    #Install TKN CLI tool
    set +x; echo "Setting up external ip..."
    mkdir ~/.tkncli
    cd ~/.tkncli
    if ! [ -x "$(command -v tkn)" ]; then
        echo "***** Installing TKN CLI v0.17.2 *****"
        if [[ "$OSTYPE"  == "linux-gnu" ]]; then
            set -x;
            curl -LO https://github.com/tektoncd/cli/releases/download/v0.17.2/tkn_0.17.2_Linux_x86_64.tar.gz
            sudo tar xvzf tkn_0.17.2_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn
            set +x;


        elif [[ "$OSTYPE" == "darwin"* ]]; then
            set -x;
            curl -LO https://github.com/tektoncd/cli/releases/download/v0.17.2/tkn_0.17.2_Darwin_x86_64.tar.gz
            sudo tar xvzf tkn_0.17.2_Darwin_x86_64.tar.gz -C /usr/local/bin tkn
            set +x;
        else
            echo "unknown OS"
        fi
    else
        echo "TKN is already installed. Let's move on"
    fi



}


environment
gke_setup
gcp_bindings
tekton