# Medispeak Developer Setup Guide with Docker Compose

This guide will walk you through the steps to set up the Medispeak backend using Docker Compose. The configuration includes two main services:

1. **Rails Backend** (`medispeak_backend`): The main application container running the Medispeak Rails backend.
2. **PostgreSQL Database** (`medispeak_db`): A database container that handles data persistence for the Medispeak application.

---

## Prerequisites

Before getting started, make sure you have the following installed on your local machine:

1. **Docker**: For containerizing and running the services.
2. **Docker Compose**: To manage the multi-container setup.

Ensure Docker and Docker Compose are properly installed and running. You can verify the installation by running:

```bash
docker --version
docker-compose --version
```

## 1. Docker Compose Configuration Overview

The `docker-compose.yml` file defines two main services: the PostgreSQL database (`medispeak_db`) and the Rails backend (`medispeak_backend`).

### 1.1 PostgreSQL Database Configuration

The `medispeak_db` service uses the official PostgreSQL image and specifies several key configurations:

- **Environment Variables**:
  - `POSTGRES_DB`: Defines the database name.
  - `POSTGRES_USER`: Sets the username for the database.
  - `POSTGRES_PASSWORD`: Sets the password for the PostgreSQL user.
- **Ports**: The container exposes the PostgreSQL port defined by `DB_PORT`.
- **Volumes**: Data is persisted across container restarts using a Docker volume (`medispeak_data`).

### 1.2 Medispeak Backend Configuration

The `medispeak_backend` service is the core Rails application. It depends on the `medispeak_db` service being healthy before starting. Key aspects:

- **Build Arguments**: The build process takes several arguments, such as `RAILS_ENV`, `BUNDLE_DEPLOYMENT`, and others for bundling gems and preparing the Rails environment.
- **Environment Variables**:
  - OpenAI credentials (`OPENAI_ACCESS_TOKEN`, `OPENAI_ORGANIZATION_ID`).
  - Object storage credentials (`SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY`, etc.; `AWS_*` for the legacy S3 service).
  - PostgreSQL database connection details (`DB_HOST`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD`).
  - Plugin-related configuration (`PLUGIN_BASE_URL`).
- **Ports**: The Rails backend exposes the port defined by `BACKEND_PORT`.
- **Volumes**: The application code is mounted inside the container using a bind mount to keep it in sync with your local development files.

---

## 2. Setting Up Environment Variables

Before running the services, you’ll need to configure environment variables. These variables control the behavior of both the Rails backend and PostgreSQL database.

1. **Create a `.env` file** in the root directory (where the `docker-compose.yml` file is located) with the following content:

```bash
# OpenAI Credentials
OPENAI_ACCESS_TOKEN=your_openai_access_token
OPENAI_ORGANIZATION_ID=your_openai_organization_id

# Plugin Configuration
PLUGIN_BASE_URL=https://medispeak-app.pages.dev

# Rails Environment
RAILS_ENV=
BUNDLE_DEPLOYMENT=1
BUNDLE_PATH="/usr/local/bundle"
BUNDLE_WITHOUT="development test"
BACKEND_PORT=3000

# Object storage. Production runs on DigitalOcean Spaces (STORAGE_SERVICE=spaces),
# co-located with the app in blr1. SPACES_REGION and SPACES_ENDPOINT default to
# blr1, so only the key, secret and bucket are required.
SPACES_ACCESS_KEY_ID=your_spaces_access_key
SPACES_SECRET_ACCESS_KEY=your_spaces_secret_key
SPACES_BUCKET=your_spaces_bucket_name

# AWS S3 Configuration (legacy; STORAGE_SERVICE=amazon)
AWS_ACCESS_KEY_ID=your_aws_access_key
AWS_SECRET_ACCESS_KEY=your_aws_secret_key
AWS_REGION=your_aws_region
AWS_BUCKET=your_s3_bucket_name

# Database Configuration (Required)
POSTGRES_IMAGE_TAG=14.2-alpine
DB_NAME=medispeak
DB_NAME_TEST=medispeak_test
DB_HOST=medispeak_db
DB_USERNAME=postgres
DB_PASSWORD=postgres
DB_PORT=5432
```

> **Note**: `RAILS_ENV` sets the environment (e.g., development, production), `BUNDLE_DEPLOYMENT` ensures only production gems install, `BUNDLE_PATH` defines the gem directory, `BUNDLE_WITHOUT` skips development/test gems, and `BACKEND_PORT` specifies the port the app runs on (default: 3000).
>
> **Note**: A sample `.env` file has been provided for reference and can be found in the [example.env](../example.env) file. This example will help guide the configuration process by specifying the required environment variables. Please review and adapt it as necessary to meet your project requirements.
>
> **Note**: Replace placeholder values (`your_openai_access_token`, `your_aws_access_key`, etc.) with actual values from your OpenAI and AWS accounts.

---

## 3. Running the Application with Docker Compose

After setting up the environment variables, you're ready to bring up the services.

### Step-by-Step Instructions

1. **Build the services**:
   Run the following command to build the Docker images for the services, using the configurations from the `docker-compose.yml` file:

   ```bash
   docker-compose build
   ```

2. **Start the services**:
   Start both the PostgreSQL and Rails backend services by running:

   ```bash
   docker-compose up -d
   ```

   - The **PostgreSQL** service (`medispeak_db`) will start first.
   - The **Rails backend** service (`medispeak_backend`) will wait for the database to be healthy before starting.

3. **Verify the setup**:
   - Once the services are up and running, the Rails backend will be available at `http://localhost:3000` (or on the port you’ve specified in the `.env` file as `BACKEND_PORT`).
   - You can check the logs for any issues or confirmations of successful setup by running:

     ```bash
     docker-compose logs
     ```

4. **Stopping the services**:
   To stop the services gracefully, run:

   ```bash
   docker-compose down
   ```

   This command will stop the running containers and remove them, but the data in your PostgreSQL volume will remain intact for future use.

---

## 4. Additional Configuration Options

- **Running Migrations**:
  After the services are running, you may need to run database migrations:

  ```bash
  docker-compose exec medispeak_backend bundle exec rails db:migrate
  ```

- **Import Seed Data**:
  After the services are running, you may need to run the following command to import the seed:

  ```bash
  docker-compose exec medispeak_backend bundle exec rails db:seed
  ```

- **Accessing the Rails Console**:
  If you need to open the Rails console for debugging or testing, you can do so by running:

  ```bash
  docker-compose exec medispeak_backend bundle exec rails console
  ```

- **Database Health Check**:
  The PostgreSQL service has a health check that ensures the database is ready before the Rails backend tries to connect. You can monitor the database’s health by checking the logs:

  ```bash
  docker-compose logs medispeak_db
  ```

---

## 5. Persistent Data with Docker Volumes

- The PostgreSQL container uses a Docker volume named `medispeak_data` to persist its data. This ensures that your data will be preserved even if the container is stopped or removed.

- The volume configuration is defined at the bottom of the `docker-compose.yml` file:

  ```yaml
  volumes:
    medispeak_data:
      driver: local
  ```

To inspect the volume data, you can run:

```bash
docker volume ls
```

---

## 6. Production Considerations

For production deployments, ensure the following:

- **AWS Credentials**: The AWS credentials in your environment variables must be set to properly manage file storage in S3.
- **RAILS_MASTER_KEY**: Ensure that you provide the correct `RAILS_MASTER_KEY` for your encrypted credentials.
- **Secret Management**: Consider using a secure secret management system, such as AWS Secrets Manager, for sensitive information like OpenAI tokens, AWS credentials, and database passwords.

---

## 7. Optional MinIO Setup for File Storage

In addition to using AWS S3 for file storage, Medispeak can be configured to use MinIO as an alternative. MinIO is an open-source object storage service that is fully compatible with the AWS S3 API. This section will guide you through setting up MinIO as the file storage service for the Medispeak backend using Docker Compose.

### 7.1 Environment Variables for MinIO

To configure MinIO as the file storage service, you'll need to update your `.env` file with the following environment variables:

```bash
# MinIO credentials for file storage (required only for production)
# These are needed to configure Active Storage with MinIO, an S3-compatible object storage service.
MINIO_ACCESS_KEY_ID=your_minio_access_key_id
MINIO_SECRET_ACCESS_KEY=your_minio_secret_access_key
MINIO_ENDPOINT=https://your_minio_endpoint.com
MINIO_BUCKET=your_minio_bucket_name
MINIO_REGION=your_minio_region
```

> **Note**: Replace `your_minio_access_key_id`, `your_minio_secret_access_key`, and `your_minio_bucket_name` with the actual credentials for your MinIO instance. The `MINIO_ENDPOINT` should point to the local MinIO service running on port [9000](http://minio:9000/).

### 7.2 Switching Between AWS and MinIO

You can switch between AWS and MinIO by modifying the `STORAGE_SERVICE` environment variable in the `.env` file:

```bash
# Default Storage Service
STORAGE_SERVICE=minio # Set to 'amazon' for AWS S3 or 'local' for local storage
```

When `STORAGE_SERVICE=minio`, the application will use MinIO for file storage. If you'd like to switch back to AWS S3, simply change the value to `amazon`.

### 7.3 Running the Application with MinIO

After configuring MinIO, you can bring up the services, including the MinIO service, by running:

```bash
docker-compose --profile minio up -d
```

> **Note**: The `--profile minio` flag ensures that the MinIO service is only brought up when needed, and the environment variables are properly set.

---

## Conclusion

By following this guide, you can get the Medispeak backend and its PostgreSQL database up and running using Docker Compose. The environment is flexible, allowing you to adjust configurations via environment variables and scale for both development and production needs.
