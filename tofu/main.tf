resource "terraform_data" "k3d_cluster" {
  input = {
    name  = var.k3d_cluster_name
    image = "rancher/k3s:${var.k3s_version}"
  }

  provisioner "local-exec" {
    command = "k3d cluster create ${self.input.name} --image ${self.input.image} --servers 1 --agents 1 -p '8080:80@loadbalancer'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.input.name}"
  }
}

resource "docker_image" "postgres" {
  name         = "postgres:16-alpine"
  keep_locally = true
}

resource "docker_container" "postgres" {
  name  = "postgres-infra-takehome"
  image = docker_image.postgres.image_id

  env = [
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=app",
  ]

  ports {
    internal = var.postgres_port
    external = var.postgres_port
  }

  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql/data"
  }

  restart = "unless-stopped"
}

resource "docker_volume" "postgres_data" {
  name = "postgres-infra-takehome-data"
}

resource "kubernetes_secret_v1" "postgrest" {
  metadata {
    name      = "postgrest"
    namespace = kubernetes_namespace_v1.postgrest.metadata[0].name
  }

  data = {
    PGUSER             = postgresql_role.postgres.name
    PGPASSWORD         = random_password.postgres.result
    PGDATABASE         = postgresql_database.postgrest.name
    PGHOST             = var.k3d_localhost_dns
    PGPORT             = var.postgres_port
    PGRST_DB_ANON_ROLE = postgresql_role.postgres.name
    PGRST_SERVER_PORT  = var.postgrest_port
  }
  type = "Opaque"
}

resource "postgresql_database" "postgrest" {
  name       = "postgrest"
  depends_on = [docker_container.postgres]
}

resource "postgresql_role" "postgres" {
  name       = "postgrest"
  login      = true
  password   = random_password.postgres.result
  superuser  = true
  depends_on = [docker_container.postgres]
}

resource "random_password" "postgres" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "kubernetes_namespace_v1" "postgrest" {
  metadata {
    name = "postgrest"
  }
}

resource "kubernetes_deployment_v1" "postgrest" {
  metadata {
    name      = "postgrest"
    namespace = kubernetes_namespace_v1.postgrest.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "postgrest"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgrest"
        }
      }

      spec {
        container {
          name  = "postgrest"
          image = "postgrest/postgrest:v14.6"

          port {
            container_port = var.postgrest_port
          }
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.postgrest.metadata[0].name
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_job_v1.psql_job]
}

resource "kubernetes_service_v1" "postgrest" {
  metadata {
    name      = "postgrest"
    namespace = kubernetes_namespace_v1.postgrest.metadata[0].name
  }

  spec {
    selector = kubernetes_deployment_v1.postgrest.spec[0].selector[0].match_labels

    type = "ClusterIP"

    port {
      port        = var.postgrest_port
      target_port = var.postgrest_port
    }
  }
}

resource "kubernetes_ingress_v1" "postgrest" {
  metadata {
    name      = "postgrest"
    namespace = kubernetes_namespace_v1.postgrest.metadata[0].name
  }

  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.postgrest.metadata[0].name
              port {
                number = var.postgrest_port
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_config_map_v1" "psql_job" {
  metadata {
    name      = "psql-job"
    namespace = kubernetes_namespace_v1.postgrest.metadata[0].name
  }

  data = {
    "init.sql" = <<SQL
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL,
    email VARCHAR(100) NOT NULL UNIQUE,
    age INT CHECK (age >= 0)
);

INSERT INTO users (name, email, age) VALUES
('Alice Johnson', 'alice.johnson@example.com', 28),
('Bob Smith', 'bob.smith@example.com', 35),
('Catherine Lee', 'catherine.lee@example.com', 22),
('David Brown', 'david.brown@example.com', 41),
('Emma Davis', 'emma.davis@example.com', 30);

SELECT * FROM users;
SQL
  }
}

resource "kubernetes_job_v1" "psql_job" {
  metadata {
    name      = "psql-job"
    namespace = kubernetes_namespace_v1.postgrest.metadata[0].name
  }

  spec {
    template {
      metadata {
        labels = {
          app = "psql-job"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "psql-job"
          image = "postgres:16"

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.psql_job.metadata[0].name
            }
          }

          volume_mount {
            name       = "sql-script"
            mount_path = "/scripts"
            read_only  = true
          }

          command = ["/bin/sh", "-c"]
          args    = ["psql -f /scripts/init.sql"]
        }

        volume {
          name = "sql-script"

          config_map {
            name = kubernetes_config_map_v1.psql_job.metadata[0].name
            items {
              key  = "init.sql"
              path = "init.sql"
            }
          }
        }
      }
    }
    backoff_limit = 8
  }
}

resource "kubernetes_secret_v1" "psql_job" {
  metadata {
    name      = "psql-job"
    namespace = kubernetes_namespace_v1.postgrest.metadata[0].name
  }

  data = {
    PGUSER     = postgresql_role.postgres.name
    PGPASSWORD = random_password.postgres.result
    PGDATABASE = postgresql_database.postgrest.name
    PGHOST     = var.k3d_localhost_dns
    PGPORT     = var.postgres_port
  }
  type = "Opaque"
}
