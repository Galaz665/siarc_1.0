-- SIARC v1.0 - Instalador general
-- Ejecutar con:
-- psql -d siarc -f sql/install.sql

\echo 'Instalando esquema SIARC v1.0...'

\i sql/SIARC_1.0.sql

\echo 'Cargando datos demo...'

\i sql/08_datos_demo.sql

\echo 'Instalación SIARC finalizada.'
