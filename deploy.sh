#!/bin/bash

set -e

TURBINIA_CONFIG="$HOME/.turbiniarc"
TURBINIA_REGION=us-central

if [[ -z "$( which terraform )" ]] ; then
  echo "Terraform CLI not found.  Please follow the instructions at "
  echo "https://learn.hashicorp.com/tutorials/terraform/install-cli to install"
  echo "the terraform CLI first."
  exit 1
fi

if [[ -z "$( which gcloud )" ]] ; then
  echo "gcloud CLI not found.  Please follow the instructions at "
  echo "https://cloud.google.com/sdk/docs/install to install the gcloud "
  echo "package first."
  exit 1
fi

if [[ -z "$DEVSHELL_PROJECT_ID" ]] ; then
  DEVSHELL_PROJECT_ID=$(gcloud config get-value project)
  ERRMSG="ERROR: Could not get configured project. Please either restart "
  ERRMSG+="Google Cloudshell, or set configured project with "
  ERRMSG+="'gcloud config set project PROJECT' when running outside of Cloudshell."
  if [[ -z "$DEVSHELL_PROJECT_ID" ]] ; then
    echo $ERRMSG
    exit 1
  fi
  echo "Environment variable \$DEVSHELL_PROJECT_ID not set"
  echo -n "Do you want to use $DEVSHELL_PROJECT_ID as the target project? (y / n) > "
  read response
  if [[ $response != "y" && $response != "Y" ]] ; then
    echo $ERRMSG
    exit 1
  fi
fi

echo "Deploying to project $DEVSHELL_PROJECT_ID"

TIMESKETCH="1"
if [[ "$*" == *--no-timesketch* ]] ; then
  TIMESKETCH="0"
  echo "--no-timesketch found: Not deploying Timesketch."
fi

# TODO: Better flag handling
DOCKER_IMAGE=""
if [[ "$*" == *--build-release-test* ]] ; then
  DOCKER_IMAGE="-var turbinia_docker_image_server=gcr.io/oss-forensics-registry/turbinia/turbinia-server-release-test:latest"
  DOCKER_IMAGE="$DOCKER_IMAGE -var turbinia_docker_image_worker=gcr.io/oss-forensics-registry/turbinia/turbinia-worker-release-test:latest"
  echo "Setting docker image to $DOCKER_IMAGE"
elif [[ "$*" == *--build-dev* ]] ; then
  DOCKER_IMAGE="-var turbinia_docker_image_server=gcr.io/oss-forensics-registry/turbinia/turbinia-server-dev:latest"
  DOCKER_IMAGE="$DOCKER_IMAGE -var turbinia_docker_image_worker=gcr.io/oss-forensics-registry/turbinia/turbinia-worker-dev:latest"
  echo "Setting docker image to $DOCKER_IMAGE"
fi

# Use local `gcloud auth` credentials rather than creating new Service Account.
if [[ "$*" != *--use-gcloud-auth* ]] ; then
  SA_NAME="terraform"
  SA_MEMBER="serviceAccount:$SA_NAME@$DEVSHELL_PROJECT_ID.iam.gserviceaccount.com"

  # Create service account
  gcloud --project $DEVSHELL_PROJECT_ID iam service-accounts create "${SA_NAME}" --display-name "${SA_NAME}"

  # Grant IAM roles to the service account
  echo "Grant permissions on service account"
  gcloud projects add-iam-policy-binding $DEVSHELL_PROJECT_ID --member=$SA_MEMBER --role='roles/editor'
  gcloud projects add-iam-policy-binding $DEVSHELL_PROJECT_ID --member=$SA_MEMBER --role='roles/compute.admin'
  gcloud projects add-iam-policy-binding $DEVSHELL_PROJECT_ID --member=$SA_MEMBER --role='roles/cloudfunctions.admin'
  gcloud projects add-iam-policy-binding $DEVSHELL_PROJECT_ID --member=$SA_MEMBER --role='roles/servicemanagement.admin'
  gcloud projects add-iam-policy-binding $DEVSHELL_PROJECT_ID --member=$SA_MEMBER --role='roles/pubsub.admin'
  gcloud projects add-iam-policy-binding $DEVSHELL_PROJECT_ID --member=$SA_MEMBER --role='roles/storage.admin'
  gcloud projects add-iam-policy-binding $DEVSHELL_PROJECT_ID --member=$SA_MEMBER --role='roles/redis.admin'
  gcloud projects add-iam-policy-binding $DEVSHELL_PROJECT_ID --member=$SA_MEMBER --role='roles/cloudsql.admin'

  # Create and fetch the service account key
  echo "Fetch and store service account key"
  gcloud --project $DEVSHELL_PROJECT_ID iam service-accounts keys create ~/key.json --iam-account "$SA_NAME@$DEVSHELL_PROJECT_ID.iam.gserviceaccount.com"
  export GOOGLE_APPLICATION_CREDENTIALS=~/key.json

# TODO: Do real check to make sure credentials have adequate roles
elif [[ $( gcloud auth list --filter="status:ACTIVE" --format="value(account)" | wc -l ) -eq 0 ]] ; then
  echo "No gcloud credentials found.  Use 'gcloud auth login' and 'gcloud auth application-default' to log in"
  exit 1
fi

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd $DIR

# Create AppEngine app, if not already exists, in order to activate datastore
# if ! gcloud services --project $DEVSHELL_PROJECT_ID list | grep appengine; then
  # gcloud app --project $DEVSHELL_PROJECT_ID create --region=$TURBINIA_REGION
# fi

# Deploy cloud functions
gcloud -q services --project $DEVSHELL_PROJECT_ID enable cloudfunctions.googleapis.com
gcloud -q services --project $DEVSHELL_PROJECT_ID enable cloudbuild.googleapis.com

# Deploying cloud functions is flaky. Retry until success.
while true; do
  num_functions="$(gcloud functions --project $DEVSHELL_PROJECT_ID list | grep task | grep $TURBINIA_REGION | wc -l)"
  if [[ "${num_functions}" -eq "3" ]]; then
    echo "All Cloud Functions deployed"
    break
  fi
  gcloud --project $DEVSHELL_PROJECT_ID -q functions deploy gettasks --region $TURBINIA_REGION --source modules/turbinia/data/ --runtime nodejs8 --trigger-http --memory 256MB --timeout 60s
  gcloud --project $DEVSHELL_PROJECT_ID -q functions deploy closetask --region $TURBINIA_REGION --source modules/turbinia/data/ --runtime nodejs8 --trigger-http --memory 256MB --timeout 60s
  gcloud --project $DEVSHELL_PROJECT_ID -q functions deploy closetasks  --region $TURBINIA_REGION --source modules/turbinia/data/ --runtime nodejs8 --trigger-http --memory 256MB --timeout 60s
done


# Run Terraform to setup the rest of the infrastructure
terraform init
if [ $TIMESKETCH -eq "1" ] ; then
  terraform apply -var gcp_project=$DEVSHELL_PROJECT_ID $DOCKER_IMAGE -auto-approve
else
  terraform apply --target=module.turbinia -var gcp_project=$DEVSHELL_PROJECT_ID $DOCKER_IMAGE -auto-approve
fi


if [ $TIMESKETCH -eq "1" ] ; then
  url="$(terraform output timesketch-server-url)"
  user="$(terraform output timesketch-admin-username)"
  pass="$(terraform output timesketch-admin-password)"

  echo
  echo "Waiting for Timesketch installation to finish. This may take a few minutes.."
  echo
  while true; do
    response="$(curl -k -o /dev/null --silent --head --write-out '%{http_code}' $url)"
    if [[ "${response}" -eq "302" ]]; then
      break
    fi
    sleep 3
  done

  echo "****************************************************************************"
  echo "Timesketch server: ${url}"
  echo "User: ${user}"
  echo "Password: ${pass}"
  echo "****************************************************************************"
fi


# Turbinia
cd ~
# TODO: Either add checks here, or possibly add a suffix with the infrastructure
# ID here.
virtualenv --python=/usr/bin/python3 turbinia
echo "Activating Turbinia virtual environment"
source turbinia/bin/activate

echo "Installing Turbinia client"
pip install turbinia 1>/dev/null
cd $DIR

if [[ -a $TURBINIA_CONFIG ]] ; then
  backup_file="${TURBINIA_CONFIG}.$( date +%s )"
  mv $TURBINIA_CONFIG $backup_file
  echo "Backing up old Turbinia config $TURBINIA_CONFIG to $backup_file"
fi

terraform output turbinia-config > $TURBINIA_CONFIG
sed -i s/"\/var\/log\/turbinia\/turbinia.log"/"\/tmp\/turbinia.log"/ $TURBINIA_CONFIG

echo
echo "Deployment done"
echo
