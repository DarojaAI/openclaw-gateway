# Schema Sources Reference

## HCL Schema

```hcl
data "hcl_schema" "<name>" {
  path = "schema.hcl"
}

env "<name>" {
  schema {
    src = data.hcl_schema.<name>.url
  }
}
```

## External Schema (ORM Integration)

The `external_schema` data source imports SQL schema from an ORM or external program.

```hcl
# GORM (Go)
data "external_schema" "gorm" {
  program = ["go", "run", "-mod=mod", "ariga.io/atlas-provider-gorm", "load", "--path", "./models", "--dialect", "postgres"]
}

# Drizzle (TypeScript)
data "external_schema" "drizzle" {
  program = ["npx", "drizzle-kit", "export"]
}

# SQLAlchemy (Python)
data "external_schema" "sqlalchemy" {
  program = ["python", "-m", "atlas_provider_sqlalchemy", "--path", "./models", "--dialect", "postgresql"]
}

# Django (Python)
data "external_schema" "django" {
  program = ["python", "manage.py", "atlas-provider-django", "--dialect", "postgresql"]
}

# Ent (Go)
env "<name>" {
  schema {
    src = "ent://ent/schema"
  }
}

# Sequelize (Node.js)
data "external_schema" "sequelize" {
  program = ["npx", "@ariga/atlas-provider-sequelize", "load", "--path", "./models", "--dialect", "postgres"]
}

# TypeORM (TypeScript)
data "external_schema" "typeorm" {
  program = ["npx", "@ariga/atlas-provider-typeorm", "load", "--path", "./entities", "--dialect", "postgres"]
}
```

Wire into an environment:

```hcl
env "<name>" {
  schema {
    src = data.external_schema.django.url
  }
}
```

**Important:** The output must be a complete SQL schema (not a diff). If errors occur, run the program directly to isolate the issue.

## Composite Schema (Pro)

Combine multiple schemas into one. Requires `atlas login`.

```hcl
data "composite_schema" "app" {
  schema "users" {
    url = data.external_schema.auth_service.url
  }
  schema "graph" {
    url = "ent://ent/schema"
  }
}

env "<name>" {
  schema {
    src = data.composite_schema.app.url
  }
}
```

## Dev Database URLs

```bash
# MySQL
--dev-url "docker://mysql/8/dev"
--dev-url "docker://mysql/8"          # database-scoped

# PostgreSQL
--dev-url "docker://postgres/15/dev?search_path=public"
--dev-url "docker://postgres/15/dev"  # database-scoped

# SQLite
--dev-url "sqlite://dev?mode=memory"

# SQL Server
--dev-url "docker://sqlserver/2022-latest/dev?mode=schema"
--dev-url "docker://sqlserver/2022-latest/dev?mode=database"

# PostGIS / pgvector
--dev-url "docker://postgis/latest/dev?search_path=public"
--dev-url "docker://pgvector/pg17/dev?search_path=public"
```

## Environment Variables and Security

**DO**: Use secure configuration patterns

```hcl
// Using environment variables (recommended)
env "<name>" {
  url = getenv("DATABASE_URL")
}

// Using external data sources
data "external" "envfile" {
  program = ["npm", "run", "envfile.js"]
}

locals {
  envfile = jsondecode(data.external.envfile)
}

env "<name>" {
  url = local.envfile.DATABASE_URL
}
```

**DON'T**: Hardcode sensitive values

```hcl
// Never do this
env "prod" {
  url = "postgres://user:password123@prod-host:5432/database"
}
```
