#!/bin/sh
set -e

gum confirm '
Are you ready to start?
Select "Yes" only if you did NOT follow the story from the start (if you jumped straight into this chapter).
Feel free to say "No" and inspect the script if you prefer setting up resources manually.
' || exit 0

echo "
## You will need following tools installed:
|Name            |Required             |More info                                          |
|----------------|---------------------|---------------------------------------------------|
|Docker          |Yes                  |'https://docs.docker.com/engine/install'           |
|gitHub CLI      |Yes                  |'https://cli.github.com/'                          |
|git CLI         |Yes                  |'https://git-scm.com/downloads'                    |
|helm CLI        |If using Helm        |'https://helm.sh/docs/intro/install/'              |
|kubectl CLI     |Yes                  |'https://kubernetes.io/docs/tasks/tools/#kubectl'  |
|kind CLI        |Yes                  |'https://kind.sigs.k8s.io/docs/user/quick-start/#installation'|
|yq CLI          |Yes                  |'https://github.com/mikefarah/yq#install'          |
|jq CLI          |Yes                  |'https://jqlang.github.io/jq/download'             |
|Google Cloud account with admin permissions|If using Google Cloud|'https://cloud.google.com'|
|Google Cloud CLI|If using Google Cloud|'https://cloud.google.com/sdk/docs/install'        |
|gke-gcloud-auth-plugin|If using Google Cloud|'https://cloud.google.com/blog/products/containers-kubernetes/kubectl-auth-changes-in-gke'|
|AWS account with admin permissions|If using AWS|'https://aws.amazon.com'                  |
|AWS CLI         |If using AWS         |'https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'|

If you are running this script from **Nix shell**, most of the requirements are already set with the exception of **Docker** and the **hyperscaler account**.
" | gum format

gum confirm "
Do you have those tools installed?
" || exit 0

rm -f .env

#############
# Variables #
#############

echo "export HYPERSCALER=$HYPERSCALER" >> .env

REGISTRY_SERVER=$(gum input \
    --placeholder "Container image registry server (e.g., ghcr.io/vfarcic)" \
    --value "$REGISTRY_SERVER")

REGISTRY_USER=$(gum input \
    --placeholder "Container image registry username (e.g., ghcr.io/vfarcic)" \
    --value "$REGISTRY_USER")

REGISTRY_PASSWORD=$(gum input \
    --placeholder "Container image registry password (e.g., ghcr.io/vfarcic)" \
    --value "$REGISTRY_PASSWORD")

##############
# Crossplane #
##############

if [[ "$HYPERSCALER" == "google" ]]; then

    gcloud auth login

    # Project

    PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)

    echo "export PROJECT_ID=$PROJECT_ID" >> .env

    gcloud projects create ${PROJECT_ID}

    # APIs

    echo "## Open https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=$PROJECT_ID in a browser and *ENABLE* the API." \
        | gum format

    gum input --placeholder "
Press the enter key to continue."

echo "## Open https://console.cloud.google.com/marketplace/product/google/secretmanager.googleapis.com?project=$PROJECT_ID in a browser and *ENABLE* the API." \
        | gum format

    gum input --placeholder "
Press the enter key to continue."

echo "## Open https://console.cloud.google.com/apis/library/sqladmin.googleapis.com?project=$PROJECT_ID in a browser and *ENABLE* the API." \
        | gum format

    gum input --placeholder "
Press the enter key to continue."

    # Service Account (general)

    export SA_NAME=devops-toolkit

    export SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

    gcloud iam service-accounts create $SA_NAME \
        --project $PROJECT_ID

    export ROLE=roles/admin

    gcloud projects add-iam-policy-binding --role $ROLE \
        $PROJECT_ID --member serviceAccount:$SA

    gcloud iam service-accounts keys create gcp-creds.json \
        --project $PROJECT_ID --iam-account $SA

    # Crossplane

    yq --inplace ".spec.projectID = \"$PROJECT_ID\"" \
        crossplane-packages/google-config.yaml

elif [[ "$HYPERSCALER" == "aws" ]]; then

    AWS_ACCESS_KEY_ID=$(gum input --placeholder "AWS Access Key ID" --value "$AWS_ACCESS_KEY_ID")
    echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env
    
    AWS_SECRET_ACCESS_KEY=$(gum input --placeholder "AWS Secret Access Key" --value "$AWS_SECRET_ACCESS_KEY" --password)
    echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> .env

    AWS_ACCOUNT_ID=$(gum input --placeholder "AWS Account ID" --value "$AWS_ACCOUNT_ID")
    echo "export AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID" >> .env

    echo "[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
" >aws-creds.conf

fi

############
# Registry #
############

kind create cluster

kubectl create secret docker-registry push-secret \
    --docker-server=$REGISTRY_SERVER \
    --docker-username=$REGISTRY_USER \
    --docker-password=$REGISTRY_PASSWORD

REGISTRY_AUTH=$(kubectl get secret push-secret \
    --output jsonpath='{.data.\.dockerconfigjson}' | base64 -d)

kubectl delete secret push-secret

if [[ "$HYPERSCALER" == "google" ]]; then

    echo "{\".dockerconfigjson\": $REGISTRY_AUTH }" \
        | gcloud secrets --project $PROJECT_ID \
        create registry-auth --data-file=-

elif [[ "$HYPERSCALER" == "aws" ]]; then

    set +e
    aws secretsmanager create-secret \
        --name registry-auth --region us-east-1 \
        --secret-string "{\".dockerconfigjson\": $REGISTRY_AUTH }"
    set -e

fi

kind delete cluster

####################
# External Secrets #
####################

if [[ "$HYPERSCALER" == "google" ]]; then

    yq --inplace \
        ".spec.provider.gcpsm.projectID = \"$PROJECT_ID\"" \
        external-secrets/google.yaml

    echo "{\"password\": \"IWillNeverTell\" }" \
        | gcloud secrets --project $PROJECT_ID \
        create db-password --data-file=-

elif [[ "$HYPERSCALER" == "aws" ]]; then

    set +e
    aws secretsmanager create-secret \
        --name db-password --region us-east-1 \
        --secret-string "{\"password\": \"IWillNeverTell\" }"
    set -e

fi

########
# Misc #
########

chmod +x setup-kubectl.sh

chmod +x setup-argocd.sh

chmod +x destroy-kubectl.sh

chmod +x destroy-argocd.sh