# Docker Container for Google Cloud VMware Engine PowerCLI

Example container that includes gcloud CLI, PowerShell, PowerCLI, and Google Cloud Power Tools

## Preparation

Create a Google Cloud IAM service account with adequate permissions. Create a JSON key file for the account and copy it to the container host. Ensure it will be readable (e.g., chmod 0644) from the container.

```bash
$ scp creds.json containerhost:creds.json
```

Edit the [`.env` file](gcloud-powershell.env) in this directory so that the credential file, project ID, zone, and region are set. The gcloud CLI will read these environment variables in order to authenticate.

## Build the container

```bash
docker build -t gcloudpower .
```

## Run the container

Use volume mapping so the container can read the JSON file, which is a [recommended practice](https://github.com/GoogleCloudPlatform/cloud-sdk-docker#usage). Do not embed credentials inside a container image.

```bash
docker run -it --rm -v `pwd`/creds.json:/app/creds.json `
--env-file gcloud-powershell.env gcloudpower
```

## Sample Code

The [Dockerfile](Dockerfile) fetches some sample PowerCLI code, imports modules, authenticates, and ends with an active PowerShell prompt. Adapt as needed.

## Demo

![Demo](images/docker-gcloud-powercli.gif?raw=true)
