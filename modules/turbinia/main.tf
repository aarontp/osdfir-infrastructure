/**
 * Copyright 2019 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  # API services to enable for the project
  services_list = [
    "compute.googleapis.com",
    "datastore.googleapis.com",
    "iam.googleapis.com",
    "pubsub.googleapis.com",
    "storage-component.googleapis.com",
    "logging.googleapis.com"
  ]
}

resource "google_project_service" "services" {
  count              = length(local.services_list)
  project            = var.gcp_project
  service            = local.services_list[count.index]
  disable_on_destroy = false
}

# Enable PubSub and create topic
resource "google_pubsub_topic" "pubsub-topic" {
  name = "turbinia-${var.infrastructure_id}"
  depends_on  = [google_project_service.services]
}

resource "google_pubsub_topic" "pubsub-topic-psq" {
  name        = "turbinia-${var.infrastructure_id}-psq"
  depends_on  = [google_project_service.services]
}

# Cloud Storage Bucket
resource "google_storage_bucket" "output-bucket" {
  name          = "turbinia-${var.infrastructure_id}"
  depends_on    = [google_project_service.services]
  uniform_bucket_level_access = true
  force_destroy = true
}

# Bucket notfication for GCS importer
resource "google_pubsub_topic" "pubsub-topic-gcs" {
  name = "turbinia-gcs-${var.infrastructure_id}"
  depends_on  = [google_project_service.services]
}

data "google_storage_project_service_account" "gcs-pubsub-account" {
}

resource "google_pubsub_topic_iam_binding" "binding" {
  topic   = google_pubsub_topic.pubsub-topic-gcs.id
  role    = "roles/pubsub.publisher"
  members = ["serviceAccount:${data.google_storage_project_service_account.gcs-pubsub-account.email_address}"]
}

resource "google_storage_notification" "notification" {
  bucket         = google_storage_bucket.output-bucket.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.pubsub-topic-gcs.id
  event_types    = ["OBJECT_FINALIZE", "OBJECT_METADATA_UPDATE"]
  custom_attributes = {
    new-attribute = "new-attribute-value"
  }
  depends_on = [google_pubsub_topic_iam_binding.binding]
}

resource "google_pubsub_subscription" "gcs-subscription" {
  name  = "turbinia-gcs-subscription-${var.infrastructure_id}"
  topic = google_pubsub_topic.pubsub-topic-gcs.name
  message_retention_duration = "1200s"
  retain_acked_messages      = true
  ack_deadline_seconds = 20
  expiration_policy {
    ttl = "300000.5s"
  }
}

resource "google_datastore_index" "index1" {
  kind = "TurbiniaTask"
  properties {
    name = "instance"
    direction = "DESCENDING"
  }
  properties {
    name = "last_update"
    direction = "DESCENDING"
  }
}

resource "google_datastore_index" "index2" {
  kind = "TurbiniaTask"
  properties {
    name = "instance"
    direction = "DESCENDING"
  }
  properties {
    name = "last_update"
    direction = "DESCENDING"
  }
  properties {
    name = "successfull"
    direction = "DESCENDING"
  }
}

resource "google_datastore_index" "index3" {
  kind = "TurbiniaTask"
  properties {
    name = "instance"
    direction = "DESCENDING"
  }
  properties {
    name = "last_update"
    direction = "DESCENDING"
  }
  properties {
    name = "request_id"
    direction = "DESCENDING"
  }
}

resource "google_datastore_index" "index4" {
  kind = "TurbiniaTask"
  properties {
    name = "id"
    direction = "DESCENDING"
  }
  properties {
    name = "instance"
    direction = "DESCENDING"
  }
  properties {
    name = "last_update"
    direction = "DESCENDING"
  }
}

resource "google_datastore_index" "index5" {
  kind = "TurbiniaTask"
  properties {
    name = "instance"
    direction = "DESCENDING"
  }
  properties {
    name = "last_update"
    direction = "DESCENDING"
  }
  properties {
    name = "request_id"
    direction = "DESCENDING"
  }
  properties {
    name = "successful"
    direction = "DESCENDING"
  }
}

resource "google_datastore_index" "index6" {
  kind = "TurbiniaTask"
  properties {
    name = "last_update"
    direction = "DESCENDING"
  }
  properties {
    name = "user"
    direction = "DESCENDING"
  }
}

resource "google_datastore_index" "index7" {
  kind = "TurbiniaTask"
  properties {
    name = "id"
    direction = "DESCENDING"
  }
  properties {
    name = "instance"
    direction = "DESCENDING"
  }
  properties {
    name = "last_update"
    direction = "DESCENDING"
  }
  properties {
    name = "user"
    direction = "DESCENDING"
  }
}

resource "google_datastore_index" "index8" {
  kind = "TurbiniaTask"
  properties {
    name = "instance"
    direction = "DESCENDING"
  }
  properties {
    name = "last_update"
    direction = "DESCENDING"
  }
  properties {
    name = "request_id"
    direction = "DESCENDING"
  }
  properties {
    name = "user"
    direction = "DESCENDING"
  }
}

resource "google_datastore_index" "index9" {
  kind = "TurbiniaTask"
  properties {
    name = "last_update"
    direction = "DESCENDING"
  }
  properties {
    name = "task_id"
    direction = "DESCENDING"
  }
}

# Template for systemd service file
data "template_file" "turbinia-systemd" {
  template = file("${path.module}/templates/turbinia.service.tpl")
}

# Turbinia config
data "template_file" "turbinia-config-template" {
  template = file("${path.module}/templates/turbinia.conf.tpl")
  vars = {
    project           = var.gcp_project
    region            = var.gcp_region
    zone              = var.gcp_zone
    turbinia_id       = var.infrastructure_id
    pubsub_topic      = google_pubsub_topic.pubsub-topic.name
    pubsub_topic_psq  = google_pubsub_topic.pubsub-topic-psq.name
    bucket            = google_storage_bucket.output-bucket.name
  }
  depends_on  = [google_project_service.services]
}

locals {
  turbinia_config = base64encode(data.template_file.turbinia-config-template.rendered)
}

# # Turbinia server
resource "google_compute_instance" "turbinia-server" {
  count        = var.turbinia_server_count
  name         = "turbinia-server-${var.infrastructure_id}"
  machine_type = var.turbinia_server_machine_type
  zone         = var.gcp_zone
  depends_on   = [google_project_service.services, google_pubsub_topic.pubsub-topic, google_pubsub_topic.pubsub-topic-psq]

  # Allow to stop/start the machine to enable change machine type.
  allow_stopping_for_update = true

  boot_disk {
    auto_delete = true
    initialize_params {
      image = var.container_base_image
      type = "pd-standard"
    }
  }

  metadata = {
    gce-container-declaration = "spec:\n  containers:\n    - name: turbinia-server\n      image: '${var.turbinia_docker_image_server}'\n      securityContext:\n        privileged: false\n      env:\n        - name: TURBINIA_CONF\n          value: \"${local.turbinia_config}\"\n      stdin: true\n      tty: true\n  restartPolicy: Always\n\n"
    google-logging-enabled = "true"
    google-monitoring-enabled = "true"
  }

  service_account {
    scopes = ["compute-ro", "storage-rw", "pubsub", "datastore"]
  }

  network_interface {
    network = "default"
  }
}

resource "google_compute_instance" "turbinia-worker" {
  count        = var.turbinia_worker_count
  name         = "turbinia-worker-${var.infrastructure_id}-${count.index}"
  machine_type = var.turbinia_worker_machine_type
  zone         = var.gcp_zone
  depends_on   = [google_project_service.services, google_compute_instance.turbinia-server]

  # Allow to stop/start the machine to enable change machine type.
  allow_stopping_for_update = true

  boot_disk {
    auto_delete = true
    initialize_params {
      image = var.container_base_image
      type = "pd-standard"
    }
  }

  metadata = {
    gce-container-declaration = "spec:\n  containers:\n    - name: turbinia-worker\n      image: '${var.turbinia_docker_image_worker}'\n      volumeMounts:\n        - name: host-path-0\n          mountPath: /dev/\n          readOnly: true\n        - name: host-path-1\n          mountPath: /var/lib/turbinia\n          readOnly: false\n      securityContext:\n        privileged: true\n      env:\n        - name: TURBINIA_CONF\n          value: \"${local.turbinia_config}\"\n      stdin: true\n      tty: true\n  restartPolicy: Always\n  volumes:\n    - name: host-path-0\n      hostPath:\n        path: /dev\n    - name: host-path-1\n      hostPath:\n        path: /var/lib/turbinia\n\n"
    google-logging-enabled = "true"
    google-monitoring-enabled = "true"
  }

  service_account {
    scopes = ["compute-rw", "storage-rw", "pubsub", "datastore", "cloud-platform"]
  }

  network_interface {
    network = "default"
  }
}
