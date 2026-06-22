-- SIARC v1.0 - Datos demo
-- No contiene información real

INSERT INTO siarc.cat_rol_usuario (rol, descripcion)
VALUES
('ADMIN', 'Administrador del sistema'),
('ANALISTA', 'Analista de crédito y riesgo'),
('CONSULTA', 'Usuario de consulta')
ON CONFLICT (rol) DO NOTHING;
