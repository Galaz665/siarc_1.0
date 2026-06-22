# SIARC

Sistema Integral de Análisis de Riesgo de Cartera

## Características

- Originación de crédito
- Administración de cartera
- Pagos y liquidaciones
- Gestión de garantías FONAGA
- Riesgo crediticio
- IFRS9
- Reportes
- Auditoría de accesos

## Tecnologías

- Python
- FastAPI
- PostgreSQL
- SQLAlchemy
- Jinja2
- Bootstrap

## Instalación

### Clonar

git clone https://github.com/usuario/siarc.git

### Crear entorno

python -m venv venv

source venv/bin/activate

### Instalar dependencias

pip install -r requirements.txt

### Variables de entorno

DATABASE_URL

SIARC_SECRET_KEY

### Ejecutar

uvicorn app:app --reload

## Licencia

GPL v3
# SIARC

Sistema Integral de Análisis de Riesgo de Cartera

## Descripción

SIARC es una plataforma de administración de crédito, riesgo y garantías desarrollada sobre PostgreSQL y FastAPI.

Permite:

* Originación de créditos
* Administración de cartera
* Pagos y liquidaciones
* Riesgo crediticio (PD, LGD, EAD)
* Reservas IFRS9
* Gestión de garantías FONAGA
* Auditoría de accesos
* Reportes operativos

---

## Tecnologías

* Python 3.14+
* FastAPI
* PostgreSQL
* SQLAlchemy
* Jinja2
* Bootstrap

---

## Instalación

### 1. Crear base de datos

```bash
createdb siarc
```

### 2. Instalar esquema

```bash
psql -d siarc -f sql/install.sql
```

### 3. Crear entorno virtual

```bash
python -m venv venv
source venv/bin/activate
```

### 4. Instalar dependencias

```bash
pip install -r requirements.txt
```

### 5. Configurar variables de entorno

```bash
export DATABASE_URL="postgresql+psycopg2://usuario:password@localhost:5432/siarc"
export SIARC_SECRET_KEY="cambiar_por_una_clave_segura"
```

### 6. Ejecutar

```bash
uvicorn app:app --host 0.0.0.0 --port 8001
```

---

## Usuarios Demo

El archivo `08_datos_demo.sql` contiene usuarios y datos ficticios para pruebas.

No contiene información real.

---

## Licencia

GNU General Public License v3.0 (GPLv3)

---

## Autor

Ilich Galaz

Proyecto SIARC - Sistema Integral de Análisis de Riesgo de Cartera.
