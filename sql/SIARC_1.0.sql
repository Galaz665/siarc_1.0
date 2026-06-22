--
-- PostgreSQL database dump
--

\restrict tMQcuAYipWCDpvXAvNgk4ymRUxPDA17L7wZeZ8YZLK9nd0aljMQtwtulsE7DfCr

-- Dumped from database version 18.4 (Ubuntu 18.4-1.pgdg26.04+1)
-- Dumped by pg_dump version 18.4 (Ubuntu 18.4-1.pgdg26.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: siarc; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA siarc;


--
-- Name: fn_actualizar_fecha_actualizacion(); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_actualizar_fecha_actualizacion() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.fecha_actualizacion = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


--
-- Name: fn_agregar_detalle_poliza(integer, character varying, text, numeric, numeric); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_agregar_detalle_poliza(p_id_poliza integer, p_cuenta character varying, p_descripcion text, p_cargo numeric DEFAULT 0, p_abono numeric DEFAULT 0) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN

    INSERT INTO siarc.tb_poliza_detalle (
        id_poliza,
        cuenta,
        descripcion,
        cargo,
        abono
    )
    VALUES (
        p_id_poliza,
        p_cuenta,
        p_descripcion,
        COALESCE(p_cargo, 0),
        COALESCE(p_abono, 0)
    );

END;
$$;


--
-- Name: fn_analizar_solicitud_credito(integer, character varying); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_analizar_solicitud_credito(p_id_solicitud integer, p_analista character varying DEFAULT 'SIARC'::character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_ingreso NUMERIC(18,2);
    v_egreso NUMERIC(18,2);
    v_disponible NUMERIC(18,2);

    v_monto NUMERIC(18,2);
    v_plazo INT;
    v_tasa NUMERIC(10,4);
    v_pago NUMERIC(18,2);

    v_valor_garantia NUMERIC(18,2);
    v_cobertura NUMERIC(10,4);

    v_monto_minimo NUMERIC(18,2);
    v_monto_maximo NUMERIC(18,2);
    v_plazo_minimo INT;
    v_plazo_maximo INT;
    v_lgd_catalogo NUMERIC(10,4);

    v_relacion_pago_ingreso NUMERIC(10,4);

    v_score_capacidad NUMERIC(10,4);
    v_score_garantia NUMERIC(10,4);
    v_score_plazo NUMERIC(10,4);
    v_score_producto NUMERIC(10,4);
    v_score_final NUMERIC(10,4);

    v_pd NUMERIC(10,8);
    v_lgd NUMERIC(10,8);
    v_ead NUMERIC(18,2);
    v_pe NUMERIC(18,2);

    v_semaforo VARCHAR(20);
    v_nivel VARCHAR(30);
    v_monto_recomendado NUMERIC(18,2);
    v_dictamen TEXT;
BEGIN

    SELECT
        ingresos_mensuales,
        egresos_mensuales,
        monto_solicitado,
        plazo_meses,
        COALESCE(tasa_interes_anual, producto_tasa_base, 0.28),
        COALESCE(valor_garantia, 0),
        producto_monto_minimo,
        producto_monto_maximo,
        producto_plazo_minimo,
        producto_plazo_maximo,
        COALESCE(lgd_catalogo, 0.60)
    INTO
        v_ingreso,
        v_egreso,
        v_monto,
        v_plazo,
        v_tasa,
        v_valor_garantia,
        v_monto_minimo,
        v_monto_maximo,
        v_plazo_minimo,
        v_plazo_maximo,
        v_lgd_catalogo
    FROM siarc.vw_solicitudes_credito_enriquecidas
    WHERE id_solicitud = p_id_solicitud;

    IF v_ingreso IS NULL THEN
        RAISE EXCEPTION 'No existe solicitud con id %', p_id_solicitud;
    END IF;

    v_disponible := v_ingreso - v_egreso;

    v_pago := (v_monto * (1 + v_tasa)) / NULLIF(v_plazo, 0);

    v_relacion_pago_ingreso := v_pago / NULLIF(v_ingreso, 0);

    v_cobertura := v_valor_garantia / NULLIF(v_monto, 0);

    v_score_capacidad :=
        CASE
            WHEN v_relacion_pago_ingreso <= 0.25 THEN 100
            WHEN v_relacion_pago_ingreso <= 0.35 THEN 80
            WHEN v_relacion_pago_ingreso <= 0.45 THEN 60
            WHEN v_relacion_pago_ingreso <= 0.60 THEN 40
            ELSE 20
        END;

    v_score_garantia :=
        CASE
            WHEN v_cobertura >= 1.50 THEN 100
            WHEN v_cobertura >= 1.00 THEN 80
            WHEN v_cobertura >= 0.70 THEN 60
            WHEN v_cobertura >= 0.40 THEN 40
            ELSE 20
        END;

    v_score_plazo :=
        CASE
            WHEN v_plazo <= 12 THEN 100
            WHEN v_plazo <= 24 THEN 80
            WHEN v_plazo <= 36 THEN 60
            WHEN v_plazo <= 48 THEN 40
            ELSE 20
        END;

    v_score_producto :=
        CASE
            WHEN v_monto_minimo IS NOT NULL
             AND v_monto < v_monto_minimo THEN 40

            WHEN v_monto_maximo IS NOT NULL
             AND v_monto > v_monto_maximo THEN 20

            WHEN v_plazo_minimo IS NOT NULL
             AND v_plazo < v_plazo_minimo THEN 50

            WHEN v_plazo_maximo IS NOT NULL
             AND v_plazo > v_plazo_maximo THEN 30

            ELSE 100
        END;

    v_score_final :=
        (v_score_capacidad * 0.45)
        + (v_score_garantia * 0.25)
        + (v_score_plazo * 0.15)
        + (v_score_producto * 0.15);

    v_pd :=
        CASE
            WHEN v_score_final >= 85 THEN 0.03
            WHEN v_score_final >= 70 THEN 0.08
            WHEN v_score_final >= 55 THEN 0.18
            WHEN v_score_final >= 40 THEN 0.35
            ELSE 0.60
        END;

    -- Ahora LGD sale del catálogo de garantía
    v_lgd := v_lgd_catalogo;

    v_ead := v_monto;

    v_pe := v_ead * v_pd * v_lgd;

    v_semaforo :=
        CASE
            WHEN v_pd >= 0.35 THEN 'ROJO'
            WHEN v_pd >= 0.10 THEN 'AMARILLO'
            ELSE 'VERDE'
        END;

    v_nivel :=
        CASE
            WHEN v_pd >= 0.35 THEN 'ALTO'
            WHEN v_pd >= 0.10 THEN 'MEDIO'
            ELSE 'BAJO'
        END;

    v_monto_recomendado :=
        CASE
            WHEN v_score_producto < 100 AND v_monto_maximo IS NOT NULL
                 AND v_monto > v_monto_maximo
                THEN v_monto_maximo

            WHEN v_semaforo = 'VERDE'
                THEN v_monto

            WHEN v_semaforo = 'AMARILLO'
                THEN v_monto * 0.80

            ELSE v_monto * 0.50
        END;

    v_dictamen :=
        CASE
            WHEN v_score_producto < 100 AND v_monto_maximo IS NOT NULL
                 AND v_monto > v_monto_maximo
                THEN 'OBSERVADO: MONTO SOLICITADO SUPERA EL LÍMITE DEL PRODUCTO'

            WHEN v_score_producto < 100 AND v_plazo_maximo IS NOT NULL
                 AND v_plazo > v_plazo_maximo
                THEN 'OBSERVADO: PLAZO SOLICITADO SUPERA EL LÍMITE DEL PRODUCTO'

            WHEN v_semaforo = 'VERDE'
                THEN 'APROBABLE'

            WHEN v_semaforo = 'AMARILLO'
                THEN 'APROBABLE CON OBSERVACIONES'

            ELSE
                'NO RECOMENDABLE EN CONDICIONES ACTUALES'
        END;

    INSERT INTO siarc.tb_analisis_credito (
        id_solicitud,
        ingreso_mensual,
        egreso_mensual,
        ingreso_disponible,
        monto_solicitado,
        plazo_meses,
        tasa_interes_anual,
        pago_estimado_mensual,
        relacion_pago_ingreso,
        valor_garantia,
        cobertura_garantia,
        score_capacidad_pago,
        score_garantia,
        score_plazo,
        score_final,
        pd_estimada,
        lgd_estimada,
        ead_estimada,
        perdida_esperada_estimada,
        semaforo,
        nivel_riesgo,
        monto_recomendado,
        dictamen,
        analista,
        observaciones
    )
    VALUES (
        p_id_solicitud,
        v_ingreso,
        v_egreso,
        v_disponible,
        v_monto,
        v_plazo,
        v_tasa,
        v_pago,
        v_relacion_pago_ingreso,
        v_valor_garantia,
        v_cobertura,
        v_score_capacidad,
        v_score_garantia,
        v_score_plazo,
        v_score_final,
        v_pd,
        v_lgd,
        v_ead,
        v_pe,
        v_semaforo,
        v_nivel,
        v_monto_recomendado,
        v_dictamen,
        p_analista,
        'Análisis generado usando catálogos de producto, garantía, actividad y destino'
    );

    UPDATE siarc.tb_solicitud_credito
    SET
        estatus = 'ANALISIS',
        score_preliminar = v_score_final,
        semaforo_preliminar = v_semaforo,
        monto_recomendado = v_monto_recomendado,
        dictamen_preliminar = v_dictamen,
        fecha_actualizacion = CURRENT_TIMESTAMP
    WHERE id_solicitud = p_id_solicitud;

    INSERT INTO siarc.tb_solicitud_historial (
        id_solicitud,
        estatus_anterior,
        estatus_nuevo,
        comentario,
        usuario
    )
    VALUES (
        p_id_solicitud,
        'CAPTURADA',
        'ANALISIS',
        'Análisis crediticio automático generado por SIARC usando catálogos',
        p_analista
    );

END;
$$;


--
-- Name: fn_aplicar_pago_credito(integer, date, numeric, character varying, character varying, character varying, text); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_aplicar_pago_credito(p_id_credito_originado integer, p_fecha_pago date, p_importe_pagado numeric, p_usuario character varying DEFAULT 'SIARC'::character varying, p_referencia_pago character varying DEFAULT NULL::character varying, p_canal_pago character varying DEFAULT 'CAJA'::character varying, p_observaciones text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_calendario INT;
    v_numero_pago INT;

    v_pago_programado NUMERIC(18,2);
    v_capital_programado NUMERIC(18,2);
    v_interes_programado NUMERIC(18,2);

    v_saldo_actual NUMERIC(18,2);
    v_saldo_posterior NUMERIC(18,2);

    v_capital_pagado NUMERIC(18,2);
    v_interes_pagado NUMERIC(18,2);
BEGIN

    SELECT saldo_actual
    INTO v_saldo_actual
    FROM siarc.tb_credito_originado
    WHERE id_credito_originado = p_id_credito_originado;

    IF v_saldo_actual IS NULL THEN
        RAISE EXCEPTION 'No existe crédito %', p_id_credito_originado;
    END IF;

    IF v_saldo_actual <= 0 THEN
        RAISE EXCEPTION 'El crédito ya está liquidado';
    END IF;

    SELECT
        id_calendario,
        numero_pago,
        pago_programado,
        capital_programado,
        interes_programado
    INTO
        v_id_calendario,
        v_numero_pago,
        v_pago_programado,
        v_capital_programado,
        v_interes_programado
    FROM siarc.tb_credito_calendario
    WHERE id_credito_originado = p_id_credito_originado
      AND estatus_pago IN ('PENDIENTE', 'PARCIAL')
    ORDER BY numero_pago
    LIMIT 1;

    IF v_id_calendario IS NULL THEN
        RAISE EXCEPTION 'No hay pagos pendientes para el crédito %', p_id_credito_originado;
    END IF;

    v_interes_pagado := LEAST(p_importe_pagado, COALESCE(v_interes_programado, 0));
    v_capital_pagado := LEAST(
        p_importe_pagado - v_interes_pagado,
        v_saldo_actual
    );

    v_saldo_posterior := ROUND(v_saldo_actual - v_capital_pagado, 2);

    INSERT INTO siarc.tb_credito_pago (
        id_credito_originado,
        id_calendario,
        numero_pago,
        fecha_pago,
        importe_pagado,
        capital_pagado,
        interes_pagado,
        saldo_anterior,
        saldo_posterior,
        usuario,
        referencia_pago,
        canal_pago,
        observaciones
    )
    VALUES (
        p_id_credito_originado,
        v_id_calendario,
        v_numero_pago,
        p_fecha_pago,
        p_importe_pagado,
        v_capital_pagado,
        v_interes_pagado,
        v_saldo_actual,
        v_saldo_posterior,
        p_usuario,
        p_referencia_pago,
        p_canal_pago,
        p_observaciones
    );

    UPDATE siarc.tb_credito_originado
    SET
        saldo_actual = v_saldo_posterior,
        estatus_credito = CASE
            WHEN v_saldo_posterior <= 0 THEN 'LIQUIDADO'
            ELSE estatus_credito
        END,
        fecha_actualizacion = now()
    WHERE id_credito_originado = p_id_credito_originado;

    UPDATE siarc.tb_credito_calendario
    SET estatus_pago = CASE
        WHEN p_importe_pagado >= v_pago_programado THEN 'PAGADO'
        ELSE 'PARCIAL'
    END
    WHERE id_calendario = v_id_calendario;

    IF v_saldo_posterior <= 0 THEN
        UPDATE siarc.tb_credito_calendario
        SET estatus_pago = 'LIQUIDADO'
        WHERE id_credito_originado = p_id_credito_originado
          AND estatus_pago IN ('PENDIENTE', 'PARCIAL');
    END IF;

    PERFORM siarc.fn_registrar_recuperacion_fonaga_si_aplica(
        p_id_credito_originado,
        v_capital_pagado,
        p_referencia_pago,
        'Recuperación FONAGA por pago normal'
    );

END;
$$;


--
-- Name: fn_asignar_cobertura_fondo(integer, character varying, numeric, text); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_asignar_cobertura_fondo(p_id_credito_originado integer, p_clave_fondo character varying, p_porcentaje_cobertura numeric DEFAULT NULL::numeric, p_observaciones text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_fondo INT;
    v_porcentaje NUMERIC(10,4);
    v_saldo NUMERIC(18,2);
BEGIN

    SELECT
        id_fondo,
        COALESCE(p_porcentaje_cobertura, porcentaje_cobertura_default)
    INTO
        v_id_fondo,
        v_porcentaje
    FROM siarc.cat_fondo_garantia
    WHERE clave = p_clave_fondo
      AND activo = TRUE;

    IF v_id_fondo IS NULL THEN
        RAISE EXCEPTION 'No existe fondo activo con clave %', p_clave_fondo;
    END IF;

    SELECT saldo_actual
    INTO v_saldo
    FROM siarc.tb_credito_originado
    WHERE id_credito_originado = p_id_credito_originado;

    IF v_saldo IS NULL THEN
        RAISE EXCEPTION 'No existe crédito originado con id %', p_id_credito_originado;
    END IF;

    INSERT INTO siarc.tb_credito_cobertura_garantia (
        id_credito_originado,
        id_fondo,
        porcentaje_cobertura,
        monto_base_cobertura,
        monto_maximo_cubierto,
        observaciones
    )
    VALUES (
        p_id_credito_originado,
        v_id_fondo,
        v_porcentaje,
        v_saldo,
        v_saldo * v_porcentaje,
        p_observaciones
    )
    ON CONFLICT (id_credito_originado, id_fondo)
    DO UPDATE SET
        porcentaje_cobertura = EXCLUDED.porcentaje_cobertura,
        monto_base_cobertura = EXCLUDED.monto_base_cobertura,
        monto_maximo_cubierto = EXCLUDED.monto_maximo_cubierto,
        observaciones = EXCLUDED.observaciones,
        estatus_cobertura = 'ACTIVA',
        fecha_alta = CURRENT_TIMESTAMP;

END;
$$;


--
-- Name: fn_asignar_mitigante_credito(integer, character varying, numeric, numeric, text); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_asignar_mitigante_credito(p_id_credito_originado integer, p_clave_mitigante character varying, p_porcentaje_cobertura numeric, p_monto_cubierto numeric DEFAULT NULL::numeric, p_observaciones text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_mitigante INT;
    v_existe_credito INT;
BEGIN

    SELECT COUNT(*)
    INTO v_existe_credito
    FROM siarc.tb_credito_originado
    WHERE id_credito_originado = p_id_credito_originado;

    IF v_existe_credito = 0 THEN
        RAISE EXCEPTION 'No existe crédito originado con id %', p_id_credito_originado;
    END IF;

    SELECT id_mitigante
    INTO v_id_mitigante
    FROM siarc.cat_mitigante_riesgo_agro
    WHERE clave = p_clave_mitigante
      AND activo = TRUE;

    IF v_id_mitigante IS NULL THEN
        RAISE EXCEPTION 'No existe mitigante activo con clave %', p_clave_mitigante;
    END IF;

    INSERT INTO siarc.tb_credito_mitigante_riesgo (
        id_credito_originado,
        id_mitigante,
        porcentaje_cobertura,
        monto_cubierto,
        observaciones
    )
    VALUES (
        p_id_credito_originado,
        v_id_mitigante,
        p_porcentaje_cobertura,
        p_monto_cubierto,
        p_observaciones
    )
    ON CONFLICT (id_credito_originado, id_mitigante)
    DO UPDATE SET
        porcentaje_cobertura = EXCLUDED.porcentaje_cobertura,
        monto_cubierto = EXCLUDED.monto_cubierto,
        observaciones = EXCLUDED.observaciones,
        activo = TRUE,
        fecha_registro = CURRENT_TIMESTAMP;

END;
$$;


--
-- Name: fn_crear_poliza_contable(character varying, character varying, text, character varying); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_crear_poliza_contable(p_clave_evento character varying, p_referencia character varying, p_descripcion text, p_origen_modulo character varying DEFAULT 'SIARC'::character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_poliza INT;
BEGIN

    INSERT INTO siarc.tb_poliza_contable (
        clave_evento,
        referencia,
        descripcion,
        origen_modulo
    )
    VALUES (
        p_clave_evento,
        p_referencia,
        p_descripcion,
        p_origen_modulo
    )
    RETURNING id_poliza INTO v_id_poliza;

    RETURN v_id_poliza;

END;
$$;


--
-- Name: fn_enviar_solicitud_comite(integer, character varying); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_enviar_solicitud_comite(p_id_solicitud integer, p_usuario character varying DEFAULT 'SIARC'::character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_estatus_actual VARCHAR(30);
BEGIN

    SELECT estatus
    INTO v_estatus_actual
    FROM siarc.tb_solicitud_credito
    WHERE id_solicitud = p_id_solicitud;

    IF v_estatus_actual IS NULL THEN
        RAISE EXCEPTION 'No existe solicitud con id %', p_id_solicitud;
    END IF;

    UPDATE siarc.tb_solicitud_credito
    SET
        estatus = 'COMITE',
        fecha_actualizacion = CURRENT_TIMESTAMP
    WHERE id_solicitud = p_id_solicitud;

    INSERT INTO siarc.tb_solicitud_historial (
        id_solicitud,
        estatus_anterior,
        estatus_nuevo,
        comentario,
        usuario
    )
    VALUES (
        p_id_solicitud,
        v_estatus_actual,
        'COMITE',
        'Solicitud enviada a comité de crédito',
        p_usuario
    );

END;
$$;


--
-- Name: fn_evaluar_riesgo_automatico(); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_evaluar_riesgo_automatico() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_modelo INT;
BEGIN
    -- Crear modelo si no existe
    INSERT INTO siarc.tb_modelo_riesgo (
        nombre_modelo,
        tipo_modelo,
        version_modelo,
        descripcion,
        parametros
    )
    SELECT
        'Modelo Automático SIARC v1',
        'HEURISTICO',
        '1.0',
        'Modelo automático basado en atraso, reestructura, castigo, saldo y garantía',
        '{"metodo":"reglas","version":"1.0"}'
    WHERE NOT EXISTS (
        SELECT 1
        FROM siarc.tb_modelo_riesgo
        WHERE nombre_modelo = 'Modelo Automático SIARC v1'
    );

    SELECT id_modelo
    INTO v_modelo
    FROM siarc.tb_modelo_riesgo
    WHERE nombre_modelo = 'Modelo Automático SIARC v1'
    LIMIT 1;

    -- Insertar evaluación automática
    INSERT INTO siarc.tb_resultado_riesgo (
        id_credito,
        id_modelo,
        fecha_evaluacion,
        score_riesgo,
        probabilidad_incumplimiento,
        severidad_perdida,
        exposicion_incumplimiento,
        perdida_esperada,
        clasificacion_riesgo,
        semaforo,
        dictamen,
        explicacion,
        detalle_resultado
    )
    SELECT
        c.id_credito,
        v_modelo,
        CURRENT_DATE,

        -- SCORE 0-100
        GREATEST(
            0,
            LEAST(
                100,
                100
                - CASE
                    WHEN c.dias_atraso = 0 THEN 0
                    WHEN c.dias_atraso BETWEEN 1 AND 30 THEN 15
                    WHEN c.dias_atraso BETWEEN 31 AND 60 THEN 35
                    WHEN c.dias_atraso BETWEEN 61 AND 90 THEN 55
                    ELSE 75
                  END
                - CASE WHEN c.reestructurado THEN 15 ELSE 0 END
                - CASE WHEN c.castigado THEN 40 ELSE 0 END
                - CASE WHEN c.saldo_actual >= 1000000 THEN 5 ELSE 0 END
            )
        ) AS score_riesgo,

        -- PD automática
        CASE
            WHEN c.castigado THEN 0.950000
            WHEN c.dias_atraso = 0 THEN 0.030000
            WHEN c.dias_atraso BETWEEN 1 AND 30 THEN 0.080000
            WHEN c.dias_atraso BETWEEN 31 AND 60 THEN 0.180000
            WHEN c.dias_atraso BETWEEN 61 AND 90 THEN 0.350000
            ELSE 0.600000
        END
        + CASE WHEN c.reestructurado THEN 0.100000 ELSE 0 END
        AS pd,

        -- LGD automática según cobertura de garantía
        CASE
            WHEN COALESCE(g.valor_recuperable_estimado, 0) >= c.saldo_actual THEN 0.250000
            WHEN COALESCE(g.valor_recuperable_estimado, 0) >= c.saldo_actual * 0.50 THEN 0.400000
            WHEN COALESCE(g.valor_recuperable_estimado, 0) > 0 THEN 0.550000
            ELSE 0.700000
        END AS lgd,

        c.saldo_actual AS ead,

        -- Pérdida esperada
        c.saldo_actual *
        (
            CASE
                WHEN c.castigado THEN 0.950000
                WHEN c.dias_atraso = 0 THEN 0.030000
                WHEN c.dias_atraso BETWEEN 1 AND 30 THEN 0.080000
                WHEN c.dias_atraso BETWEEN 31 AND 60 THEN 0.180000
                WHEN c.dias_atraso BETWEEN 61 AND 90 THEN 0.350000
                ELSE 0.600000
            END
            + CASE WHEN c.reestructurado THEN 0.100000 ELSE 0 END
        )
        *
        (
            CASE
                WHEN COALESCE(g.valor_recuperable_estimado, 0) >= c.saldo_actual THEN 0.250000
                WHEN COALESCE(g.valor_recuperable_estimado, 0) >= c.saldo_actual * 0.50 THEN 0.400000
                WHEN COALESCE(g.valor_recuperable_estimado, 0) > 0 THEN 0.550000
                ELSE 0.700000
            END
        ) AS perdida_esperada,

        -- Clasificación
        CASE
            WHEN c.castigado OR c.dias_atraso > 90 THEN 'CRITICO'
            WHEN c.dias_atraso BETWEEN 61 AND 90 THEN 'ALTO'
            WHEN c.dias_atraso BETWEEN 31 AND 60 THEN 'MEDIO'
            WHEN c.dias_atraso BETWEEN 1 AND 30 THEN 'MEDIO'
            ELSE 'BAJO'
        END AS clasificacion_riesgo,

        -- Semáforo
        CASE
            WHEN c.castigado OR c.dias_atraso > 90 THEN 'ROJO'
            WHEN c.dias_atraso BETWEEN 31 AND 90 THEN 'AMARILLO'
            WHEN c.dias_atraso BETWEEN 1 AND 30 THEN 'AMARILLO'
            ELSE 'VERDE'
        END AS semaforo,

        -- Dictamen
        CASE
            WHEN c.castigado OR c.dias_atraso > 90 THEN 'NO RECOMENDABLE'
            WHEN c.dias_atraso BETWEEN 31 AND 90 THEN 'REQUIERE SEGUIMIENTO'
            WHEN c.dias_atraso BETWEEN 1 AND 30 THEN 'APROBADO CON OBSERVACIONES'
            ELSE 'APROBADO'
        END AS dictamen,

        -- Explicación
        'Evaluación automática basada en días de atraso, reestructura, castigo, saldo y garantía.' AS explicacion,

        jsonb_build_object(
            'dias_atraso', c.dias_atraso,
            'reestructurado', c.reestructurado,
            'castigado', c.castigado,
            'saldo_actual', c.saldo_actual,
            'valor_recuperable_garantia', COALESCE(g.valor_recuperable_estimado, 0)
        ) AS detalle_resultado

    FROM siarc.tb_credito c
    LEFT JOIN (
        SELECT
            id_credito,
            SUM(valor_recuperable_estimado) AS valor_recuperable_estimado
        FROM siarc.tb_garantia
        WHERE activo = TRUE
        GROUP BY id_credito
    ) g ON c.id_credito = g.id_credito
    WHERE c.saldo_actual > 0;
END;
$$;


--
-- Name: fn_formalizar_credito(integer, character varying); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_formalizar_credito(p_id_solicitud integer, p_usuario character varying DEFAULT 'SIARC'::character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_estatus VARCHAR(30);
    v_codigo VARCHAR(50);

    v_nombre VARCHAR(250);
    v_curp VARCHAR(18);
    v_rfc VARCHAR(13);
    v_producto VARCHAR(100);
    v_destino TEXT;

    v_monto NUMERIC(18,2);
    v_plazo INT;
    v_tasa NUMERIC(10,4);
BEGIN

    SELECT estatus
    INTO v_estatus
    FROM siarc.tb_solicitud_credito
    WHERE id_solicitud = p_id_solicitud;

    IF v_estatus IS NULL THEN
        RAISE EXCEPTION 'No existe solicitud con id %', p_id_solicitud;
    END IF;

    IF v_estatus <> 'APROBADA' THEN
        RAISE EXCEPTION 'La solicitud % no está aprobada. Estatus actual: %',
            p_id_solicitud, v_estatus;
    END IF;

    SELECT
        'CRED-' || LPAD(p_id_solicitud::TEXT, 6, '0'),
        s.nombre || ' ' || COALESCE(s.paterno, '') || ' ' || COALESCE(s.materno, ''),
        s.curp,
        s.rfc,
        s.producto_solicitado,
        s.destino_credito,
        c.monto_aprobado,
        c.plazo_aprobado,
        c.tasa_aprobada
    INTO
        v_codigo,
        v_nombre,
        v_curp,
        v_rfc,
        v_producto,
        v_destino,
        v_monto,
        v_plazo,
        v_tasa
    FROM siarc.tb_solicitud_credito s
    JOIN LATERAL (
        SELECT *
        FROM siarc.tb_comite_credito c
        WHERE c.id_solicitud = s.id_solicitud
        ORDER BY c.fecha_comite DESC
        LIMIT 1
    ) c ON TRUE
    WHERE s.id_solicitud = p_id_solicitud;

    IF v_monto IS NULL OR v_monto <= 0 THEN
        RAISE EXCEPTION 'No existe monto aprobado válido para solicitud %', p_id_solicitud;
    END IF;

    INSERT INTO siarc.tb_credito_originado (
        id_solicitud,
        codigo_credito,
        nombre_acreditado,
        curp,
        rfc,
        producto,
        destino_credito,
        monto_aprobado,
        plazo_meses,
        tasa_interes_anual,
        saldo_inicial,
        saldo_actual
    )
    VALUES (
        p_id_solicitud,
        v_codigo,
        v_nombre,
        v_curp,
        v_rfc,
        v_producto,
        v_destino,
        v_monto,
        v_plazo,
        v_tasa,
        v_monto,
        v_monto
    )
    ON CONFLICT (codigo_credito) DO NOTHING;

    INSERT INTO siarc.tb_solicitud_historial (
        id_solicitud,
        estatus_anterior,
        estatus_nuevo,
        comentario,
        usuario
    )
    VALUES (
        p_id_solicitud,
        'APROBADA',
        'APROBADA',
        'Crédito formalizado con código ' || v_codigo,
        p_usuario
    );

END;
$$;


--
-- Name: fn_generar_alertas_automaticas(); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_generar_alertas_automaticas() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO siarc.tb_alerta_temprana (
        id_credito,
        id_resultado,
        fecha_alerta,
        tipo_alerta,
        nivel_alerta,
        descripcion,
        recomendacion
    )
    SELECT
        r.id_credito,
        r.id_resultado,
        CURRENT_DATE,
        CASE
            WHEN c.dias_atraso > 90 THEN 'MORA CRITICA'
            WHEN c.dias_atraso BETWEEN 31 AND 90 THEN 'MORA MEDIA'
            WHEN c.dias_atraso BETWEEN 1 AND 30 THEN 'MORA TEMPRANA'
            ELSE 'SEGUIMIENTO'
        END,
        CASE
            WHEN c.dias_atraso > 90 THEN 'CRITICO'
            WHEN c.dias_atraso BETWEEN 61 AND 90 THEN 'ALTO'
            WHEN c.dias_atraso BETWEEN 31 AND 60 THEN 'MEDIO'
            WHEN c.dias_atraso BETWEEN 1 AND 30 THEN 'BAJO'
            ELSE 'BAJO'
        END,
        'Alerta generada automáticamente por el motor SIARC.',
        CASE
            WHEN c.dias_atraso > 90 THEN 'Enviar a recuperación especializada.'
            WHEN c.dias_atraso BETWEEN 31 AND 90 THEN 'Contactar cliente y solicitar plan de regularización.'
            WHEN c.dias_atraso BETWEEN 1 AND 30 THEN 'Realizar recordatorio preventivo.'
            ELSE 'Monitorear comportamiento.'
        END
    FROM siarc.vw_ultimo_riesgo_credito r
    JOIN siarc.tb_credito c
        ON r.id_credito = c.id_credito
    WHERE c.dias_atraso > 0;
END;
$$;


--
-- Name: fn_generar_calendario_credito(integer, date); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_generar_calendario_credito(p_id_credito_originado integer, p_fecha_primer_pago date) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_monto NUMERIC(18,2);
    v_saldo NUMERIC(18,2);
    v_plazo INT;
    v_tasa_anual NUMERIC(10,6);
    v_tasa_mensual NUMERIC(10,8);
    v_pago NUMERIC(18,2);

    v_numero INT;
    v_interes NUMERIC(18,2);
    v_capital NUMERIC(18,2);
    v_saldo_final NUMERIC(18,2);
BEGIN

    SELECT
        monto_aprobado,
        plazo_meses,
        tasa_interes_anual
    INTO
        v_monto,
        v_plazo,
        v_tasa_anual
    FROM siarc.tb_credito_originado
    WHERE id_credito_originado = p_id_credito_originado;

    IF v_monto IS NULL THEN
        RAISE EXCEPTION 'No existe crédito originado con id %', p_id_credito_originado;
    END IF;

    -- Si la tasa viene como 28, la convierte a 0.28
    IF v_tasa_anual > 1 THEN
        v_tasa_anual := v_tasa_anual / 100;
    END IF;

    v_tasa_mensual := v_tasa_anual / 12;
    v_saldo := v_monto;

    -- Pago mensual amortizado
    IF v_tasa_mensual > 0 THEN
        v_pago := ROUND(
            v_monto * (
                v_tasa_mensual * POWER(1 + v_tasa_mensual, v_plazo)
            ) / (
                POWER(1 + v_tasa_mensual, v_plazo) - 1
            ),
            2
        );
    ELSE
        v_pago := ROUND(v_monto / v_plazo, 2);
    END IF;

    DELETE FROM siarc.tb_credito_calendario
    WHERE id_credito_originado = p_id_credito_originado;

    FOR v_numero IN 1..v_plazo LOOP

        v_interes := ROUND(v_saldo * v_tasa_mensual, 2);
        v_capital := ROUND(v_pago - v_interes, 2);

        IF v_numero = v_plazo THEN
            v_capital := v_saldo;
            v_pago := v_capital + v_interes;
        END IF;

        v_saldo_final := ROUND(v_saldo - v_capital, 2);

        INSERT INTO siarc.tb_credito_calendario (
            id_credito_originado,
            numero_pago,
            fecha_vencimiento,
            saldo_inicial,
            capital_programado,
            interes_programado,
            pago_programado,
            saldo_final,
            estatus_pago
        )
        VALUES (
            p_id_credito_originado,
            v_numero,
            p_fecha_primer_pago + ((v_numero - 1) || ' months')::INTERVAL,
            v_saldo,
            v_capital,
            v_interes,
            v_pago,
            v_saldo_final,
            'PENDIENTE'
        );

        v_saldo := v_saldo_final;

    END LOOP;

END;
$$;


--
-- Name: fn_generar_poliza_desembolso(integer); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_generar_poliza_desembolso(p_id_credito_originado integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_poliza INT;
    v_codigo VARCHAR(50);
    v_monto NUMERIC(18,2);
BEGIN

    SELECT
        codigo_credito,
        monto_aprobado
    INTO
        v_codigo,
        v_monto
    FROM siarc.tb_credito_originado
    WHERE id_credito_originado = p_id_credito_originado;

    IF v_codigo IS NULL THEN
        RAISE EXCEPTION 'No existe crédito originado con id %', p_id_credito_originado;
    END IF;

    v_id_poliza := siarc.fn_crear_poliza_contable(
        'DESEMBOLSO',
        v_codigo,
        'Desembolso del crédito ' || v_codigo,
        'CREDITO'
    );

    PERFORM siarc.fn_agregar_detalle_poliza(
        v_id_poliza,
        '1201',
        'Cargo a cartera vigente',
        v_monto,
        0
    );

    PERFORM siarc.fn_agregar_detalle_poliza(
        v_id_poliza,
        '1101',
        'Salida de bancos por desembolso',
        0,
        v_monto
    );

    RETURN v_id_poliza;

END;
$$;


--
-- Name: fn_generar_poliza_pago_credito(integer); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_generar_poliza_pago_credito(p_id_pago integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_poliza INT;
    v_codigo VARCHAR(50);
    v_importe NUMERIC(18,2);
    v_capital NUMERIC(18,2);
    v_interes NUMERIC(18,2);
BEGIN

    SELECT
        c.codigo_credito,
        p.importe_pagado,
        COALESCE(p.capital_pagado,0),
        COALESCE(p.interes_pagado,0)
    INTO
        v_codigo,
        v_importe,
        v_capital,
        v_interes
    FROM siarc.tb_credito_pago p
    JOIN siarc.tb_credito_originado c
        ON p.id_credito_originado = c.id_credito_originado
    WHERE p.id_pago = p_id_pago;

    IF v_codigo IS NULL THEN
        RAISE EXCEPTION 'No existe pago con id %', p_id_pago;
    END IF;

    v_id_poliza := siarc.fn_crear_poliza_contable(
        'PAGO_CREDITO',
        v_codigo,
        'Pago recibido del crédito ' || v_codigo,
        'PAGOS'
    );

    PERFORM siarc.fn_agregar_detalle_poliza(
        v_id_poliza,
        '1101',
        'Entrada a bancos por pago recibido',
        v_importe,
        0
    );

    IF v_capital > 0 THEN
        PERFORM siarc.fn_agregar_detalle_poliza(
            v_id_poliza,
            '1201',
            'Abono a cartera vigente por capital',
            0,
            v_capital
        );
    END IF;

    IF v_interes > 0 THEN
        PERFORM siarc.fn_agregar_detalle_poliza(
            v_id_poliza,
            '4101',
            'Ingreso por intereses cobrados',
            0,
            v_interes
        );
    END IF;

    RETURN v_id_poliza;

END;
$$;


--
-- Name: fn_generar_poliza_pago_fonaga(integer); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_generar_poliza_pago_fonaga(p_id_pago_garantia integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_poliza INT;
    v_codigo VARCHAR(50);
    v_monto NUMERIC(18,2);
BEGIN

    SELECT
        v.codigo_credito,
        p.monto_pagado_fondo
    INTO
        v_codigo,
        v_monto
    FROM siarc.tb_pago_garantia_fondo p
    JOIN siarc.tb_reclamacion_garantia r
        ON p.id_reclamacion = r.id_reclamacion
    JOIN siarc.tb_credito_cobertura_garantia c
        ON r.id_cobertura = c.id_cobertura
    JOIN siarc.tb_credito_originado v
        ON c.id_credito_originado = v.id_credito_originado
    WHERE p.id_pago_garantia = p_id_pago_garantia;

    IF v_codigo IS NULL THEN
        RAISE EXCEPTION 'No existe pago de garantía con id %', p_id_pago_garantia;
    END IF;

    v_id_poliza := siarc.fn_crear_poliza_contable(
        'PAGO_FONAGA',
        v_codigo,
        'Pago recibido de fondo de garantía para crédito ' || v_codigo,
        'FONAGA'
    );

    PERFORM siarc.fn_agregar_detalle_poliza(
        v_id_poliza,
        '1101',
        'Entrada a bancos por pago de garantía',
        v_monto,
        0
    );

    PERFORM siarc.fn_agregar_detalle_poliza(
        v_id_poliza,
        '4102',
        'Recuperación por pago de garantía',
        0,
        v_monto
    );

    RETURN v_id_poliza;

END;
$$;


--
-- Name: fn_generar_poliza_recuperacion_post_garantia(integer); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_generar_poliza_recuperacion_post_garantia(p_id_recuperacion integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_poliza INT;
    v_codigo VARCHAR(50);
    v_total NUMERIC(18,2);
    v_fondo NUMERIC(18,2);
    v_inst NUMERIC(18,2);
BEGIN

    SELECT
        cr.codigo_credito,
        rec.monto_recuperado,
        rec.monto_para_fondo,
        rec.monto_para_institucion
    INTO
        v_codigo,
        v_total,
        v_fondo,
        v_inst
    FROM siarc.tb_recuperacion_post_garantia rec
    JOIN siarc.tb_reclamacion_garantia r
        ON rec.id_reclamacion = r.id_reclamacion
    JOIN siarc.tb_credito_cobertura_garantia c
        ON r.id_cobertura = c.id_cobertura
    JOIN siarc.tb_credito_originado cr
        ON c.id_credito_originado = cr.id_credito_originado
    WHERE rec.id_recuperacion = p_id_recuperacion;

    IF v_codigo IS NULL THEN
        RAISE EXCEPTION 'No existe recuperación post garantía con id %', p_id_recuperacion;
    END IF;

    v_id_poliza := siarc.fn_crear_poliza_contable(
        'RECUPERACION_POST_GARANTIA',
        v_codigo,
        'Recuperación posterior a garantía para crédito ' || v_codigo,
        'FONAGA'
    );

    PERFORM siarc.fn_agregar_detalle_poliza(
        v_id_poliza,
        '1101',
        'Entrada a bancos por recuperación posterior',
        v_total,
        0
    );

    IF v_fondo > 0 THEN
        PERFORM siarc.fn_agregar_detalle_poliza(
            v_id_poliza,
            '6101',
            'Recuperación correspondiente al fondo de garantía',
            0,
            v_fondo
        );
    END IF;

    IF v_inst > 0 THEN
        PERFORM siarc.fn_agregar_detalle_poliza(
            v_id_poliza,
            '4102',
            'Recuperación correspondiente a la institución',
            0,
            v_inst
        );
    END IF;

    RETURN v_id_poliza;

END;
$$;


--
-- Name: fn_generar_poliza_reserva_ifrs9(character varying); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_generar_poliza_reserva_ifrs9(p_codigo_credito character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_poliza INT;
    v_reserva NUMERIC(18,2);
BEGIN

    SELECT
        ROUND(reserva_neta_institucion, 2)
    INTO
        v_reserva
    FROM siarc.vw_reporte_reservas_ifrs9
    WHERE codigo_credito = p_codigo_credito;

    IF v_reserva IS NULL THEN
        RAISE EXCEPTION 'No existe reserva para el crédito %', p_codigo_credito;
    END IF;

    v_id_poliza := siarc.fn_crear_poliza_contable(
        'RESERVA_IFRS9',
        p_codigo_credito,
        'Constitución de reserva IFRS9 para crédito ' || p_codigo_credito,
        'RIESGO'
    );

    PERFORM siarc.fn_agregar_detalle_poliza(
        v_id_poliza,
        '5101',
        'Gasto por reserva crediticia IFRS9',
        v_reserva,
        0
    );

    PERFORM siarc.fn_agregar_detalle_poliza(
        v_id_poliza,
        '2101',
        'Reserva preventiva de crédito',
        0,
        v_reserva
    );

    RETURN v_id_poliza;

END;
$$;


--
-- Name: fn_generar_snapshot_cartera(); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_generar_snapshot_cartera() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO siarc.tb_snapshot_cartera (
        total_creditos,
        creditos_con_saldo,
        creditos_con_atraso,
        creditos_sin_atraso,
        monto_original_total,
        saldo_total,
        saldo_vigente_total,
        saldo_vencido_total,
        imor,
        pd_promedio,
        lgd_promedio,
        ead_total,
        perdida_esperada_total,
        perdida_esperada_sobre_cartera
    )
    SELECT
        total_creditos,
        creditos_con_saldo,
        creditos_con_atraso,
        creditos_sin_atraso,
        monto_original_total,
        saldo_total,
        saldo_vigente_total,
        saldo_vencido_total,
        imor,
        pd_promedio,
        lgd_promedio,
        ead_total,
        perdida_esperada_total,
        perdida_esperada_sobre_cartera
    FROM siarc.vw_resumen_ejecutivo;
END;
$$;


--
-- Name: fn_guardar_matriz_markov_calculada(); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_guardar_matriz_markov_calculada() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO siarc.tb_matriz_markov_calculada (
        estado_origen,
        estado_destino,
        total_movimientos,
        probabilidad
    )
    SELECT
        estado_origen,
        estado_destino,
        total_movimientos,
        probabilidad
    FROM siarc.vw_markov_matriz_real;
END;
$$;


--
-- Name: fn_liquidar_credito(integer, date, character varying, character varying, text, character varying); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_liquidar_credito(p_id_credito_originado integer, p_fecha_pago date, p_referencia_pago character varying DEFAULT NULL::character varying, p_canal_pago character varying DEFAULT 'CAJA'::character varying, p_observaciones text DEFAULT NULL::text, p_usuario character varying DEFAULT 'SIARC_WEB'::character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_saldo NUMERIC(18,2);
    v_codigo VARCHAR(50);
    v_id_pago INT;
BEGIN

    SELECT saldo_actual, codigo_credito
    INTO v_saldo, v_codigo
    FROM siarc.tb_credito_originado
    WHERE id_credito_originado = p_id_credito_originado;

    IF v_saldo IS NULL THEN
        RAISE EXCEPTION 'No existe crédito %', p_id_credito_originado;
    END IF;

    IF v_saldo <= 0 THEN
        RAISE EXCEPTION 'El crédito ya está liquidado';
    END IF;

    INSERT INTO siarc.tb_credito_pago (
        id_credito_originado,
        id_calendario,
        numero_pago,
        fecha_pago,
        importe_pagado,
        capital_pagado,
        interes_pagado,
        saldo_anterior,
        saldo_posterior,
        usuario,
        referencia_pago,
        canal_pago,
        observaciones
    )
    VALUES (
        p_id_credito_originado,
        NULL,
        NULL,
        p_fecha_pago,
        v_saldo,
        v_saldo,
        0,
        v_saldo,
        0,
        p_usuario,
        p_referencia_pago,
        p_canal_pago,
        p_observaciones
    )
    RETURNING id_pago INTO v_id_pago;

    PERFORM siarc.fn_registrar_recuperacion_fonaga_si_aplica(
        p_id_credito_originado,
        v_saldo,
        p_referencia_pago,
        'Recuperación FONAGA por liquidación total del crédito'
    );

    UPDATE siarc.tb_credito_originado
    SET
        saldo_actual = 0,
        estatus_credito = 'LIQUIDADO',
        fecha_actualizacion = now()
    WHERE id_credito_originado = p_id_credito_originado;

    UPDATE siarc.tb_credito_calendario
    SET estatus_pago = 'LIQUIDADO'
    WHERE id_credito_originado = p_id_credito_originado
      AND estatus_pago IN ('PENDIENTE', 'PARCIAL');

    UPDATE siarc.tb_credito_cobertura_garantia
    SET
        estatus_cobertura =
            CASE
                WHEN estatus_cobertura = 'ACTIVA' THEN 'LIBERADA'
                WHEN estatus_cobertura = 'RECLAMADA' THEN 'CERRADA_POR_RECUPERACION'
                ELSE estatus_cobertura
            END,
        observaciones = COALESCE(observaciones, '') ||
            ' | Cerrada por liquidación del crédito el ' || CURRENT_DATE
    WHERE id_credito_originado = p_id_credito_originado
      AND estatus_cobertura IN ('ACTIVA', 'RECLAMADA');

    PERFORM siarc.fn_generar_poliza_pago_credito(v_id_pago);

END;
$$;


--
-- Name: fn_montecarlo_cartera(integer); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_montecarlo_cartera(p_escenarios integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_simulacion INT;
    v_perdida_base NUMERIC(18,2);
BEGIN

    SELECT SUM(perdida_esperada)
    INTO v_perdida_base
    FROM siarc.mv_riesgo_cartera;

    INSERT INTO siarc.tb_montecarlo_cartera (
        numero_escenarios,
        perdida_esperada_base
    )
    VALUES (
        p_escenarios,
        v_perdida_base
    )
    RETURNING id_simulacion INTO v_id_simulacion;

    INSERT INTO siarc.tb_montecarlo_escenario (
        id_simulacion,
        numero_escenario,
        perdida_total
    )
    SELECT
        v_id_simulacion,
        escenario,
        SUM(
            ead
            *
            LEAST(
                1,
                GREATEST(
                    0,
                    pd * (0.70 + random() * 0.60)
                )
            )
            *
            LEAST(
                1,
                GREATEST(
                    0,
                    lgd * (0.80 + random() * 0.40)
                )
            )
        ) AS perdida_total
    FROM generate_series(1, p_escenarios) escenario
    CROSS JOIN siarc.mv_riesgo_cartera
    GROUP BY escenario;

    WITH ordenado AS (
        SELECT
            perdida_total,
            percent_rank() OVER (ORDER BY perdida_total) AS pr
        FROM siarc.tb_montecarlo_escenario
        WHERE id_simulacion = v_id_simulacion
    ),
    resumen AS (
        SELECT
            AVG(perdida_total) AS perdida_promedio,
            MIN(perdida_total) AS perdida_minima,
            MAX(perdida_total) AS perdida_maxima,
            MIN(perdida_total) FILTER (WHERE pr >= 0.95) AS var_95,
            MIN(perdida_total) FILTER (WHERE pr >= 0.99) AS var_99
        FROM ordenado
    )
    UPDATE siarc.tb_montecarlo_cartera mc
    SET
        perdida_promedio = r.perdida_promedio,
        perdida_minima = r.perdida_minima,
        perdida_maxima = r.perdida_maxima,
        var_95 = r.var_95,
        var_99 = r.var_99,
        perdida_inesperada_95 = r.var_95 - mc.perdida_esperada_base,
        perdida_inesperada_99 = r.var_99 - mc.perdida_esperada_base
    FROM resumen r
    WHERE mc.id_simulacion = v_id_simulacion;

END;
$$;


--
-- Name: fn_montecarlo_ia_cartera(integer); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_montecarlo_ia_cartera(p_escenarios integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_simulacion INT;
    v_perdida_base NUMERIC(18,2);
BEGIN
    SELECT SUM(perdida_esperada_ia)
    INTO v_perdida_base
    FROM siarc.vw_riesgo_con_ia;

    INSERT INTO siarc.tb_montecarlo_ia_cartera (
        numero_escenarios,
        perdida_esperada_ia_base
    )
    VALUES (
        p_escenarios,
        v_perdida_base
    )
    RETURNING id_simulacion INTO v_id_simulacion;

    INSERT INTO siarc.tb_montecarlo_ia_escenario (
        id_simulacion,
        numero_escenario,
        perdida_total
    )
    SELECT
        v_id_simulacion,
        escenario,
        SUM(
            ead
            *
            LEAST(1, GREATEST(0, pd_final * (0.70 + random() * 0.60)))
            *
            LEAST(1, GREATEST(0, lgd * (0.80 + random() * 0.40)))
        ) AS perdida_total
    FROM generate_series(1, p_escenarios) escenario
    CROSS JOIN siarc.vw_riesgo_con_ia
    GROUP BY escenario;

    WITH ordenado AS (
        SELECT
            perdida_total,
            percent_rank() OVER (ORDER BY perdida_total) AS pr
        FROM siarc.tb_montecarlo_ia_escenario
        WHERE id_simulacion = v_id_simulacion
    ),
    resumen AS (
        SELECT
            AVG(perdida_total) AS perdida_promedio,
            MIN(perdida_total) AS perdida_minima,
            MAX(perdida_total) AS perdida_maxima,
            MIN(perdida_total) FILTER (WHERE pr >= 0.95) AS var_95,
            MIN(perdida_total) FILTER (WHERE pr >= 0.99) AS var_99
        FROM ordenado
    )
    UPDATE siarc.tb_montecarlo_ia_cartera mc
    SET
        perdida_promedio = r.perdida_promedio,
        perdida_minima = r.perdida_minima,
        perdida_maxima = r.perdida_maxima,
        var_95 = r.var_95,
        var_99 = r.var_99,
        perdida_inesperada_95 = r.var_95 - mc.perdida_esperada_ia_base,
        perdida_inesperada_99 = r.var_99 - mc.perdida_esperada_ia_base
    FROM resumen r
    WHERE mc.id_simulacion = v_id_simulacion;
END;
$$;


--
-- Name: fn_proyeccion_markov(integer); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_proyeccion_markov(p_horizonte integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    i INT;
BEGIN
    -- Limpia proyecciones previas del mismo horizonte del día
    DELETE FROM siarc.tb_proyeccion_markov
    WHERE horizonte_meses = p_horizonte
      AND fecha_proyeccion::DATE = CURRENT_DATE;

    -- Tabla temporal inicial
    DROP TABLE IF EXISTS tmp_markov_actual;
    CREATE TEMP TABLE tmp_markov_actual AS
    SELECT
        estado_markov,
        SUM(total_creditos)::NUMERIC(18,6) AS creditos,
        SUM(saldo_total)::NUMERIC(18,2) AS saldo
    FROM siarc.vw_markov_distribucion_actual
    GROUP BY estado_markov;

    -- Iteraciones
    FOR i IN 1..p_horizonte LOOP

        DROP TABLE IF EXISTS tmp_markov_siguiente;

        CREATE TEMP TABLE tmp_markov_siguiente AS
        SELECT
            m.estado_destino AS estado_markov,
            SUM(a.creditos * m.probabilidad)::NUMERIC(18,6) AS creditos,
            SUM(a.saldo * m.probabilidad)::NUMERIC(18,2) AS saldo
        FROM tmp_markov_actual a
        JOIN siarc.tb_matriz_markov_base m
            ON a.estado_markov = m.estado_origen
        GROUP BY m.estado_destino;

        DROP TABLE IF EXISTS tmp_markov_actual;

        CREATE TEMP TABLE tmp_markov_actual AS
        SELECT
            estado_markov,
            creditos,
            saldo
        FROM tmp_markov_siguiente;

    END LOOP;

    -- Guarda resultado final del horizonte
    INSERT INTO siarc.tb_proyeccion_markov (
        horizonte_meses,
        estado_markov,
        creditos_esperados,
        saldo_esperado
    )
    SELECT
        p_horizonte,
        estado_markov,
        creditos,
        saldo
    FROM tmp_markov_actual;

END;
$$;


--
-- Name: fn_proyeccion_markov_ia(integer); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_proyeccion_markov_ia(p_horizonte integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    i INT;
BEGIN
    DELETE FROM siarc.tb_proyeccion_markov_ia
    WHERE horizonte_meses = p_horizonte
      AND fecha_proyeccion::DATE = CURRENT_DATE;

    DROP TABLE IF EXISTS tmp_markov_ia_actual;

    CREATE TEMP TABLE tmp_markov_ia_actual AS
    SELECT
        id_credito,
        estado_markov,
        saldo_actual::NUMERIC(18,2) AS saldo
    FROM siarc.vw_estado_markov_ia_actual;

    FOR i IN 1..p_horizonte LOOP

        DROP TABLE IF EXISTS tmp_markov_ia_siguiente;

        CREATE TEMP TABLE tmp_markov_ia_siguiente AS
        SELECT
            a.id_credito,
            m.estado_destino AS estado_markov,
            SUM(a.saldo * m.probabilidad_ajustada)::NUMERIC(18,2) AS saldo
        FROM tmp_markov_ia_actual a
        JOIN siarc.vw_matriz_markov_ia m
            ON a.id_credito = m.id_credito
           AND a.estado_markov = m.estado_origen
        GROUP BY
            a.id_credito,
            m.estado_destino;

        DROP TABLE IF EXISTS tmp_markov_ia_actual;

        CREATE TEMP TABLE tmp_markov_ia_actual AS
        SELECT
            id_credito,
            estado_markov,
            saldo
        FROM tmp_markov_ia_siguiente;

    END LOOP;

    INSERT INTO siarc.tb_proyeccion_markov_ia (
        horizonte_meses,
        estado_markov,
        creditos_esperados,
        saldo_esperado
    )
    SELECT
        p_horizonte,
        estado_markov,
        COUNT(*)::NUMERIC(18,6) AS creditos_esperados,
        SUM(saldo)::NUMERIC(18,2) AS saldo_esperado
    FROM tmp_markov_ia_actual
    GROUP BY estado_markov;

END;
$$;


--
-- Name: fn_reclamar_garantia_fondo(integer, character varying, numeric, text); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_reclamar_garantia_fondo(p_id_credito_originado integer, p_clave_fondo character varying, p_saldo_reclamado numeric DEFAULT NULL::numeric, p_observaciones text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_cobertura INT;
    v_porcentaje NUMERIC(10,4);
    v_saldo NUMERIC(18,2);
    v_saldo_reclamado NUMERIC(18,2);
    v_monto_fondo NUMERIC(18,2);
    v_monto_inst NUMERIC(18,2);
    v_dias_atraso INT;
    v_etapa VARCHAR(30);
BEGIN

    SELECT
        dias_atraso,
        etapa_riesgo,
        saldo_actual
    INTO
        v_dias_atraso,
        v_etapa,
        v_saldo
    FROM siarc.vw_cartera_crediticia
    WHERE id_credito_originado = p_id_credito_originado;

    IF v_saldo IS NULL THEN
        RAISE EXCEPTION 'No existe crédito originado con id %', p_id_credito_originado;
    END IF;

    IF v_etapa <> 'ETAPA 3' OR v_dias_atraso < 180 THEN
        RAISE EXCEPTION
        'Crédito no elegible para reclamación. Etapa: %, días atraso: %. Requiere ETAPA 3 y mínimo 180 días.',
        v_etapa, v_dias_atraso;
    END IF;

    SELECT
        c.id_cobertura,
        c.porcentaje_cobertura
    INTO
        v_id_cobertura,
        v_porcentaje
    FROM siarc.tb_credito_cobertura_garantia c
    JOIN siarc.cat_fondo_garantia f
        ON c.id_fondo = f.id_fondo
    WHERE c.id_credito_originado = p_id_credito_originado
      AND f.clave = p_clave_fondo
      AND c.estatus_cobertura = 'ACTIVA';

    IF v_id_cobertura IS NULL THEN
        RAISE EXCEPTION 'No existe cobertura activa para crédito % y fondo %',
            p_id_credito_originado, p_clave_fondo;
    END IF;

    v_saldo_reclamado := COALESCE(p_saldo_reclamado, v_saldo);

    IF v_saldo_reclamado <= 0 THEN
        RAISE EXCEPTION 'El saldo reclamado debe ser mayor a cero';
    END IF;

    IF v_saldo_reclamado > v_saldo THEN
        RAISE EXCEPTION 'El saldo reclamado % no puede ser mayor al saldo actual %',
            v_saldo_reclamado, v_saldo;
    END IF;

    v_monto_fondo := ROUND(v_saldo_reclamado * v_porcentaje, 2);
    v_monto_inst := ROUND(v_saldo_reclamado - v_monto_fondo, 2);

    INSERT INTO siarc.tb_reclamacion_garantia (
        id_cobertura,
        saldo_reclamado,
        porcentaje_cobertura,
        monto_reclamado_fondo,
        monto_a_cargo_institucion,
        observaciones
    )
    VALUES (
        v_id_cobertura,
        v_saldo_reclamado,
        v_porcentaje,
        v_monto_fondo,
        v_monto_inst,
        p_observaciones
    );

    UPDATE siarc.tb_credito_cobertura_garantia
    SET estatus_cobertura = 'RECLAMADA'
    WHERE id_cobertura = v_id_cobertura;

END;
$$;


--
-- Name: fn_registrar_bitacora(character varying, character varying, character varying, character varying, text, jsonb); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_registrar_bitacora(p_usuario character varying, p_modulo character varying, p_accion character varying, p_referencia character varying, p_descripcion text, p_datos_adicionales jsonb DEFAULT NULL::jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN

    INSERT INTO siarc.tb_bitacora_auditoria (
        usuario,
        modulo,
        accion,
        referencia,
        descripcion,
        datos_adicionales
    )
    VALUES (
        p_usuario,
        p_modulo,
        p_accion,
        p_referencia,
        p_descripcion,
        p_datos_adicionales
    );

END;
$$;


--
-- Name: fn_registrar_gestion_cobranza(integer, character varying, character varying, text, boolean, date, numeric, character varying); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_registrar_gestion_cobranza(p_id_credito_originado integer, p_tipo_gestion character varying, p_resultado_gestion character varying, p_comentario text DEFAULT NULL::text, p_promesa_pago boolean DEFAULT false, p_fecha_promesa_pago date DEFAULT NULL::date, p_monto_promesa_pago numeric DEFAULT NULL::numeric, p_usuario character varying DEFAULT 'SIARC'::character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_existe INT;
BEGIN

    SELECT COUNT(*)
    INTO v_existe
    FROM siarc.tb_credito_originado
    WHERE id_credito_originado = p_id_credito_originado;

    IF v_existe = 0 THEN
        RAISE EXCEPTION 'No existe crédito originado con id %', p_id_credito_originado;
    END IF;

    INSERT INTO siarc.tb_gestion_cobranza (
        id_credito_originado,
        tipo_gestion,
        resultado_gestion,
        comentario,
        promesa_pago,
        fecha_promesa_pago,
        monto_promesa_pago,
        usuario
    )
    VALUES (
        p_id_credito_originado,
        p_tipo_gestion,
        p_resultado_gestion,
        p_comentario,
        p_promesa_pago,
        p_fecha_promesa_pago,
        p_monto_promesa_pago,
        p_usuario
    );

END;
$$;


--
-- Name: fn_registrar_log_acceso(character varying, character varying, character varying, character varying, text); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_registrar_log_acceso(p_usuario character varying, p_rol character varying, p_ip character varying, p_evento character varying, p_descripcion text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN

    INSERT INTO siarc.tb_log_acceso(
        usuario,
        rol,
        ip_origen,
        evento,
        descripcion
    )
    VALUES(
        p_usuario,
        p_rol,
        p_ip,
        p_evento,
        p_descripcion
    );

END;
$$;


--
-- Name: fn_registrar_pago_garantia_fondo(integer, numeric, character varying, text); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_registrar_pago_garantia_fondo(p_id_reclamacion integer, p_monto_pagado_fondo numeric, p_referencia_pago character varying DEFAULT NULL::character varying, p_observaciones text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_monto_reclamado NUMERIC(18,2);
    v_pagado_actual NUMERIC(18,2);
BEGIN

    SELECT monto_reclamado_fondo
    INTO v_monto_reclamado
    FROM siarc.tb_reclamacion_garantia
    WHERE id_reclamacion = p_id_reclamacion;

    IF v_monto_reclamado IS NULL THEN
        RAISE EXCEPTION 'No existe reclamación %', p_id_reclamacion;
    END IF;

    IF p_monto_pagado_fondo <= 0 THEN
        RAISE EXCEPTION 'El monto pagado por el fondo debe ser mayor a cero';
    END IF;

    SELECT COALESCE(SUM(monto_pagado_fondo),0)
    INTO v_pagado_actual
    FROM siarc.tb_pago_garantia_fondo
    WHERE id_reclamacion = p_id_reclamacion;

    IF v_pagado_actual + p_monto_pagado_fondo > v_monto_reclamado THEN
        RAISE EXCEPTION 'El pago acumulado del fondo excede el monto reclamado. Reclamado: %, pagado actual: %, nuevo pago: %',
            v_monto_reclamado, v_pagado_actual, p_monto_pagado_fondo;
    END IF;

    INSERT INTO siarc.tb_pago_garantia_fondo (
        id_reclamacion,
        monto_pagado_fondo,
        referencia_pago,
        observaciones
    )
    VALUES (
        p_id_reclamacion,
        p_monto_pagado_fondo,
        p_referencia_pago,
        p_observaciones
    );

    UPDATE siarc.tb_reclamacion_garantia
    SET estatus_reclamacion =
        CASE
            WHEN v_pagado_actual + p_monto_pagado_fondo >= v_monto_reclamado
            THEN 'PAGADA'
            ELSE 'PAGO_PARCIAL'
        END
    WHERE id_reclamacion = p_id_reclamacion;

END;
$$;


--
-- Name: fn_registrar_recuperacion_fonaga_si_aplica(integer, numeric, character varying, text); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_registrar_recuperacion_fonaga_si_aplica(p_id_credito_originado integer, p_monto_recuperado numeric, p_referencia_pago character varying DEFAULT NULL::character varying, p_observaciones text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_reclamacion INT;
    v_id_recuperacion_antes INT;
    v_id_recuperacion_nueva INT;
BEGIN

    SELECT r.id_reclamacion
    INTO v_id_reclamacion
    FROM siarc.tb_reclamacion_garantia r
    JOIN siarc.tb_credito_cobertura_garantia g
        ON r.id_cobertura = g.id_cobertura
    WHERE g.id_credito_originado = p_id_credito_originado
      AND r.estatus_reclamacion IN ('RECLAMADA', 'PAGADA', 'PARCIAL')
    ORDER BY r.id_reclamacion DESC
    LIMIT 1;

    IF v_id_reclamacion IS NOT NULL
       AND COALESCE(p_monto_recuperado, 0) > 0 THEN

        SELECT COALESCE(MAX(id_recuperacion), 0)
        INTO v_id_recuperacion_antes
        FROM siarc.tb_recuperacion_post_garantia;

        PERFORM siarc.fn_registrar_recuperacion_post_garantia(
            v_id_reclamacion,
            p_monto_recuperado,
            COALESCE(
                p_referencia_pago,
                'REC-AUTO-' || v_id_reclamacion || '-' || CURRENT_DATE
            ),
            COALESCE(
                p_observaciones,
                'Recuperación automática posterior a garantía'
            )
        );

        SELECT MAX(id_recuperacion)
        INTO v_id_recuperacion_nueva
        FROM siarc.tb_recuperacion_post_garantia
        WHERE id_recuperacion > v_id_recuperacion_antes
          AND id_reclamacion = v_id_reclamacion;

        IF v_id_recuperacion_nueva IS NOT NULL THEN
            PERFORM siarc.fn_generar_poliza_recuperacion_post_garantia(
                v_id_recuperacion_nueva
            );
        END IF;

    END IF;

END;
$$;


--
-- Name: fn_registrar_recuperacion_post_garantia(integer, numeric, character varying, text); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_registrar_recuperacion_post_garantia(p_id_reclamacion integer, p_monto_recuperado numeric, p_referencia_recuperacion character varying DEFAULT NULL::character varying, p_observaciones text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_porcentaje NUMERIC(10,4);
    v_pagado_fondo NUMERIC(18,2);
    v_monto_fondo NUMERIC(18,2);
    v_monto_inst NUMERIC(18,2);
BEGIN

    SELECT porcentaje_cobertura
    INTO v_porcentaje
    FROM siarc.tb_reclamacion_garantia
    WHERE id_reclamacion = p_id_reclamacion;

    IF v_porcentaje IS NULL THEN
        RAISE EXCEPTION 'No existe reclamación %', p_id_reclamacion;
    END IF;

    SELECT COALESCE(SUM(monto_pagado_fondo),0)
    INTO v_pagado_fondo
    FROM siarc.tb_pago_garantia_fondo
    WHERE id_reclamacion = p_id_reclamacion;

    IF v_pagado_fondo <= 0 THEN
        RAISE EXCEPTION 'No se puede registrar recuperación post garantía sin pago previo del fondo';
    END IF;

    IF p_monto_recuperado <= 0 THEN
        RAISE EXCEPTION 'El monto recuperado debe ser mayor a cero';
    END IF;

    v_monto_fondo := ROUND(p_monto_recuperado * v_porcentaje, 2);
    v_monto_inst := ROUND(p_monto_recuperado - v_monto_fondo, 2);

    INSERT INTO siarc.tb_recuperacion_post_garantia (
        id_reclamacion,
        monto_recuperado,
        porcentaje_fondo,
        monto_para_fondo,
        monto_para_institucion,
        referencia_recuperacion,
        observaciones
    )
    VALUES (
        p_id_reclamacion,
        p_monto_recuperado,
        v_porcentaje,
        v_monto_fondo,
        v_monto_inst,
        p_referencia_recuperacion,
        p_observaciones
    );

END;
$$;


--
-- Name: fn_resolver_comite_credito(integer, character varying, numeric, integer, numeric, text, text, character varying); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_resolver_comite_credito(p_id_solicitud integer, p_decision character varying, p_monto_aprobado numeric, p_plazo_aprobado integer, p_tasa_aprobada numeric, p_condiciones text DEFAULT NULL::text, p_comentarios text DEFAULT NULL::text, p_usuario character varying DEFAULT 'COMITE'::character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_estatus_actual VARCHAR(30);
    v_estatus_nuevo VARCHAR(30);
BEGIN

    SELECT estatus
    INTO v_estatus_actual
    FROM siarc.tb_solicitud_credito
    WHERE id_solicitud = p_id_solicitud;

    IF v_estatus_actual IS NULL THEN
        RAISE EXCEPTION 'No existe solicitud con id %', p_id_solicitud;
    END IF;

    IF p_decision IN ('APROBADO', 'APROBADO_CONDICIONADO') THEN
        v_estatus_nuevo := 'APROBADA';
    ELSIF p_decision = 'RECHAZADO' THEN
        v_estatus_nuevo := 'RECHAZADA';
    ELSE
        v_estatus_nuevo := 'VALIDACION';
    END IF;

    INSERT INTO siarc.tb_comite_credito (
        id_solicitud,
        decision,
        monto_aprobado,
        plazo_aprobado,
        tasa_aprobada,
        condiciones,
        comentarios,
        usuario_comite
    )
    VALUES (
        p_id_solicitud,
        p_decision,
        p_monto_aprobado,
        p_plazo_aprobado,
        p_tasa_aprobada,
        p_condiciones,
        p_comentarios,
        p_usuario
    );

    UPDATE siarc.tb_solicitud_credito
    SET
        estatus = v_estatus_nuevo,
        fecha_actualizacion = CURRENT_TIMESTAMP
    WHERE id_solicitud = p_id_solicitud;

    INSERT INTO siarc.tb_solicitud_historial (
        id_solicitud,
        estatus_anterior,
        estatus_nuevo,
        comentario,
        usuario
    )
    VALUES (
        p_id_solicitud,
        v_estatus_actual,
        v_estatus_nuevo,
        'Resolución de comité: ' || p_decision,
        p_usuario
    );

END;
$$;


--
-- Name: fn_snapshot_markov(); Type: FUNCTION; Schema: siarc; Owner: -
--

CREATE FUNCTION siarc.fn_snapshot_markov() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN

    INSERT INTO siarc.tb_markov_historico (
        fecha_corte,
        id_credito,
        estado_markov,
        saldo_actual
    )
    SELECT
        CURRENT_DATE,
        id_credito,
        estado_markov,
        saldo_actual
    FROM siarc.vw_estado_markov_actual;

END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: cat_actividad_economica; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_actividad_economica (
    id_actividad integer NOT NULL,
    clave character varying(50) NOT NULL,
    nombre_actividad character varying(150) NOT NULL,
    sector character varying(100),
    descripcion text,
    activo boolean DEFAULT true
);


--
-- Name: cat_actividad_economica_id_actividad_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_actividad_economica_id_actividad_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_actividad_economica_id_actividad_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_actividad_economica_id_actividad_seq OWNED BY siarc.cat_actividad_economica.id_actividad;


--
-- Name: cat_clasificacion_riesgo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_clasificacion_riesgo (
    id_clasificacion_riesgo integer NOT NULL,
    clasificacion text NOT NULL,
    nivel integer,
    descripcion text
);


--
-- Name: cat_clasificacion_riesgo_id_clasificacion_riesgo_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_clasificacion_riesgo_id_clasificacion_riesgo_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_clasificacion_riesgo_id_clasificacion_riesgo_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_clasificacion_riesgo_id_clasificacion_riesgo_seq OWNED BY siarc.cat_clasificacion_riesgo.id_clasificacion_riesgo;


--
-- Name: cat_cuenta_contable; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_cuenta_contable (
    id_cuenta integer NOT NULL,
    cuenta character varying(30) NOT NULL,
    nombre_cuenta character varying(150) NOT NULL,
    tipo_cuenta character varying(50) NOT NULL,
    naturaleza character varying(20) NOT NULL,
    activa boolean DEFAULT true
);


--
-- Name: cat_cuenta_contable_id_cuenta_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_cuenta_contable_id_cuenta_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_cuenta_contable_id_cuenta_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_cuenta_contable_id_cuenta_seq OWNED BY siarc.cat_cuenta_contable.id_cuenta;


--
-- Name: cat_decision_comite; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_decision_comite (
    id_decision integer NOT NULL,
    clave character varying(30) NOT NULL,
    descripcion text
);


--
-- Name: cat_decision_comite_id_decision_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_decision_comite_id_decision_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_decision_comite_id_decision_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_decision_comite_id_decision_seq OWNED BY siarc.cat_decision_comite.id_decision;


--
-- Name: cat_destino_credito; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_destino_credito (
    id_destino integer NOT NULL,
    clave character varying(50) NOT NULL,
    nombre_destino character varying(150) NOT NULL,
    descripcion text,
    activo boolean DEFAULT true
);


--
-- Name: cat_destino_credito_id_destino_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_destino_credito_id_destino_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_destino_credito_id_destino_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_destino_credito_id_destino_seq OWNED BY siarc.cat_destino_credito.id_destino;


--
-- Name: cat_escenario_stress; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_escenario_stress (
    id_escenario integer NOT NULL,
    escenario text NOT NULL,
    descripcion text
);


--
-- Name: cat_escenario_stress_id_escenario_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_escenario_stress_id_escenario_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_escenario_stress_id_escenario_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_escenario_stress_id_escenario_seq OWNED BY siarc.cat_escenario_stress.id_escenario;


--
-- Name: cat_estado_credito; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_estado_credito (
    id_estado_credito integer NOT NULL,
    estado_credito text NOT NULL,
    descripcion text
);


--
-- Name: cat_estado_credito_id_estado_credito_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_estado_credito_id_estado_credito_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_estado_credito_id_estado_credito_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_estado_credito_id_estado_credito_seq OWNED BY siarc.cat_estado_credito.id_estado_credito;


--
-- Name: cat_estatus_solicitud; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_estatus_solicitud (
    id_estatus integer NOT NULL,
    clave character varying(30) NOT NULL,
    descripcion text
);


--
-- Name: cat_estatus_solicitud_id_estatus_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_estatus_solicitud_id_estatus_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_estatus_solicitud_id_estatus_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_estatus_solicitud_id_estatus_seq OWNED BY siarc.cat_estatus_solicitud.id_estatus;


--
-- Name: cat_etapa_riesgo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_etapa_riesgo (
    id_etapa_riesgo integer NOT NULL,
    etapa_riesgo text NOT NULL,
    descripcion text
);


--
-- Name: cat_etapa_riesgo_id_etapa_riesgo_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_etapa_riesgo_id_etapa_riesgo_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_etapa_riesgo_id_etapa_riesgo_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_etapa_riesgo_id_etapa_riesgo_seq OWNED BY siarc.cat_etapa_riesgo.id_etapa_riesgo;


--
-- Name: cat_evento_contable; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_evento_contable (
    id_evento integer NOT NULL,
    clave character varying(50) NOT NULL,
    descripcion text,
    activo boolean DEFAULT true
);


--
-- Name: cat_evento_contable_id_evento_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_evento_contable_id_evento_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_evento_contable_id_evento_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_evento_contable_id_evento_seq OWNED BY siarc.cat_evento_contable.id_evento;


--
-- Name: cat_fondo_garantia; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_fondo_garantia (
    id_fondo integer NOT NULL,
    clave character varying(50) NOT NULL,
    nombre character varying(150) NOT NULL,
    descripcion text,
    porcentaje_cobertura_default numeric(10,4),
    activo boolean DEFAULT true
);


--
-- Name: cat_fondo_garantia_id_fondo_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_fondo_garantia_id_fondo_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_fondo_garantia_id_fondo_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_fondo_garantia_id_fondo_seq OWNED BY siarc.cat_fondo_garantia.id_fondo;


--
-- Name: cat_frecuencia_pago; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_frecuencia_pago (
    id_frecuencia_pago integer NOT NULL,
    frecuencia_pago text NOT NULL,
    descripcion text
);


--
-- Name: cat_frecuencia_pago_id_frecuencia_pago_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_frecuencia_pago_id_frecuencia_pago_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_frecuencia_pago_id_frecuencia_pago_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_frecuencia_pago_id_frecuencia_pago_seq OWNED BY siarc.cat_frecuencia_pago.id_frecuencia_pago;


--
-- Name: cat_mitigante_riesgo_agro; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_mitigante_riesgo_agro (
    id_mitigante integer NOT NULL,
    clave character varying(50) NOT NULL,
    nombre character varying(150) NOT NULL,
    tipo character varying(50) NOT NULL,
    descripcion text,
    factor_reduccion_lgd numeric(10,4),
    activo boolean DEFAULT true
);


--
-- Name: cat_mitigante_riesgo_agro_id_mitigante_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_mitigante_riesgo_agro_id_mitigante_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_mitigante_riesgo_agro_id_mitigante_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_mitigante_riesgo_agro_id_mitigante_seq OWNED BY siarc.cat_mitigante_riesgo_agro.id_mitigante;


--
-- Name: cat_parametro_reserva_ifrs9; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_parametro_reserva_ifrs9 (
    id_parametro integer NOT NULL,
    etapa_riesgo character varying(30) NOT NULL,
    descripcion text,
    factor_reserva numeric(10,4) NOT NULL,
    activo boolean DEFAULT true
);


--
-- Name: cat_parametro_reserva_ifrs9_id_parametro_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_parametro_reserva_ifrs9_id_parametro_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_parametro_reserva_ifrs9_id_parametro_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_parametro_reserva_ifrs9_id_parametro_seq OWNED BY siarc.cat_parametro_reserva_ifrs9.id_parametro;


--
-- Name: cat_producto; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_producto (
    id_producto integer NOT NULL,
    codigo_producto character varying(50),
    nombre_producto text NOT NULL,
    tipo_producto text,
    descripcion text,
    activo boolean DEFAULT true,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: cat_producto_credito; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_producto_credito (
    id_producto integer NOT NULL,
    clave character varying(50) NOT NULL,
    nombre_producto character varying(150) NOT NULL,
    descripcion text,
    monto_minimo numeric(18,2),
    monto_maximo numeric(18,2),
    plazo_minimo_meses integer,
    plazo_maximo_meses integer,
    tasa_anual_base numeric(10,4),
    activo boolean DEFAULT true
);


--
-- Name: cat_producto_credito_id_producto_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_producto_credito_id_producto_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_producto_credito_id_producto_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_producto_credito_id_producto_seq OWNED BY siarc.cat_producto_credito.id_producto;


--
-- Name: cat_producto_id_producto_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_producto_id_producto_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_producto_id_producto_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_producto_id_producto_seq OWNED BY siarc.cat_producto.id_producto;


--
-- Name: cat_reserva_riesgo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_reserva_riesgo (
    id_reserva integer NOT NULL,
    etapa_riesgo character varying(20),
    porcentaje_reserva numeric(10,6)
);


--
-- Name: cat_reserva_riesgo_id_reserva_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_reserva_riesgo_id_reserva_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_reserva_riesgo_id_reserva_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_reserva_riesgo_id_reserva_seq OWNED BY siarc.cat_reserva_riesgo.id_reserva;


--
-- Name: cat_resultado_gestion_cobranza; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_resultado_gestion_cobranza (
    id_resultado integer NOT NULL,
    clave character varying(50) NOT NULL,
    descripcion text
);


--
-- Name: cat_resultado_gestion_cobranza_id_resultado_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_resultado_gestion_cobranza_id_resultado_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_resultado_gestion_cobranza_id_resultado_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_resultado_gestion_cobranza_id_resultado_seq OWNED BY siarc.cat_resultado_gestion_cobranza.id_resultado;


--
-- Name: cat_rol_usuario; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_rol_usuario (
    rol character varying(30) NOT NULL,
    descripcion text
);


--
-- Name: cat_semaforo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_semaforo (
    id_semaforo integer NOT NULL,
    semaforo text NOT NULL,
    descripcion text
);


--
-- Name: cat_semaforo_id_semaforo_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_semaforo_id_semaforo_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_semaforo_id_semaforo_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_semaforo_id_semaforo_seq OWNED BY siarc.cat_semaforo.id_semaforo;


--
-- Name: cat_sucursal; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_sucursal (
    id_sucursal integer NOT NULL,
    codigo_sucursal character varying(50),
    nombre_sucursal text NOT NULL,
    estado text,
    municipio text,
    activo boolean DEFAULT true,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: cat_sucursal_id_sucursal_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_sucursal_id_sucursal_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_sucursal_id_sucursal_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_sucursal_id_sucursal_seq OWNED BY siarc.cat_sucursal.id_sucursal;


--
-- Name: cat_tipo_garantia; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_tipo_garantia (
    id_tipo_garantia integer NOT NULL,
    tipo_garantia text NOT NULL,
    descripcion text,
    activo boolean DEFAULT true
);


--
-- Name: cat_tipo_garantia_credito; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_tipo_garantia_credito (
    id_tipo_garantia_credito integer NOT NULL,
    clave character varying(50) NOT NULL,
    nombre_garantia character varying(150) NOT NULL,
    descripcion text,
    factor_lgd numeric(10,4),
    activo boolean DEFAULT true
);


--
-- Name: cat_tipo_garantia_credito_id_tipo_garantia_credito_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_tipo_garantia_credito_id_tipo_garantia_credito_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_tipo_garantia_credito_id_tipo_garantia_credito_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_tipo_garantia_credito_id_tipo_garantia_credito_seq OWNED BY siarc.cat_tipo_garantia_credito.id_tipo_garantia_credito;


--
-- Name: cat_tipo_garantia_id_tipo_garantia_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_tipo_garantia_id_tipo_garantia_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_tipo_garantia_id_tipo_garantia_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_tipo_garantia_id_tipo_garantia_seq OWNED BY siarc.cat_tipo_garantia.id_tipo_garantia;


--
-- Name: cat_tipo_gestion_cobranza; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.cat_tipo_gestion_cobranza (
    id_tipo_gestion integer NOT NULL,
    clave character varying(50) NOT NULL,
    descripcion text
);


--
-- Name: cat_tipo_gestion_cobranza_id_tipo_gestion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.cat_tipo_gestion_cobranza_id_tipo_gestion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cat_tipo_gestion_cobranza_id_tipo_gestion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.cat_tipo_gestion_cobranza_id_tipo_gestion_seq OWNED BY siarc.cat_tipo_gestion_cobranza.id_tipo_gestion;


--
-- Name: tb_cliente; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_cliente (
    id_cliente integer NOT NULL,
    codigo_cliente_externo character varying(100),
    nombre_cliente text NOT NULL,
    rfc character varying(13),
    curp character varying(18),
    tipo_persona text,
    fecha_nacimiento date,
    sexo text,
    actividad_economica text,
    estado text,
    municipio text,
    localidad text,
    codigo_postal character varying(10),
    telefono text,
    correo text,
    fecha_alta date DEFAULT CURRENT_DATE,
    activo boolean DEFAULT true,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT tb_cliente_tipo_persona_check CHECK ((tipo_persona = ANY (ARRAY['FISICA'::text, 'MORAL'::text])))
);


--
-- Name: TABLE tb_cliente; Type: COMMENT; Schema: siarc; Owner: -
--

COMMENT ON TABLE siarc.tb_cliente IS 'Clientes normalizados del sistema SIARC. Pueden venir de Mifos u otro origen.';


--
-- Name: tb_credito; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_credito (
    id_credito integer NOT NULL,
    codigo_credito_externo character varying(100),
    id_cliente integer NOT NULL,
    id_producto integer,
    id_sucursal integer,
    id_estado_credito integer,
    id_frecuencia_pago integer,
    fecha_otorgamiento date NOT NULL,
    fecha_vencimiento date,
    plazo_meses integer,
    monto_original numeric(16,2) NOT NULL,
    saldo_actual numeric(16,2) NOT NULL,
    saldo_capital numeric(16,2) DEFAULT 0,
    saldo_interes numeric(16,2) DEFAULT 0,
    saldo_moratorio numeric(16,2) DEFAULT 0,
    tasa_interes_anual numeric(10,6),
    dias_atraso integer DEFAULT 0,
    numero_pagos_pactados integer,
    numero_pagos_realizados integer DEFAULT 0,
    fecha_ultimo_pago date,
    monto_ultimo_pago numeric(16,2),
    reestructurado boolean DEFAULT false,
    castigado boolean DEFAULT false,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT tb_credito_dias_atraso_check CHECK ((dias_atraso >= 0)),
    CONSTRAINT tb_credito_monto_original_check CHECK ((monto_original >= (0)::numeric)),
    CONSTRAINT tb_credito_plazo_meses_check CHECK ((plazo_meses > 0)),
    CONSTRAINT tb_credito_saldo_actual_check CHECK ((saldo_actual >= (0)::numeric))
);


--
-- Name: TABLE tb_credito; Type: COMMENT; Schema: siarc; Owner: -
--

COMMENT ON TABLE siarc.tb_credito IS 'Cartera de créditos normalizada para análisis de riesgo.';


--
-- Name: tb_garantia; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_garantia (
    id_garantia integer NOT NULL,
    codigo_garantia_externo character varying(100),
    id_credito integer NOT NULL,
    id_tipo_garantia integer,
    descripcion text,
    valor_garantia numeric(16,2),
    valor_recuperable_estimado numeric(16,2),
    fecha_valuacion date,
    porcentaje_cobertura numeric(10,6),
    activo boolean DEFAULT true,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT tb_garantia_valor_garantia_check CHECK ((valor_garantia >= (0)::numeric))
);


--
-- Name: TABLE tb_garantia; Type: COMMENT; Schema: siarc; Owner: -
--

COMMENT ON TABLE siarc.tb_garantia IS 'Garantías asociadas a créditos.';


--
-- Name: tb_resultado_riesgo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_resultado_riesgo (
    id_resultado integer NOT NULL,
    id_credito integer NOT NULL,
    id_modelo integer,
    fecha_evaluacion date DEFAULT CURRENT_DATE,
    score_riesgo numeric(10,4),
    probabilidad_incumplimiento numeric(10,8),
    severidad_perdida numeric(10,8),
    exposicion_incumplimiento numeric(18,2),
    perdida_esperada numeric(18,2),
    clasificacion_riesgo text,
    semaforo text,
    dictamen text,
    explicacion text,
    detalle_resultado jsonb,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE tb_resultado_riesgo; Type: COMMENT; Schema: siarc; Owner: -
--

COMMENT ON TABLE siarc.tb_resultado_riesgo IS 'Resultado consolidado del motor de riesgo por crédito.';


--
-- Name: vw_ultimo_riesgo_credito; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_ultimo_riesgo_credito AS
 WITH ultimo AS (
         SELECT rr.id_resultado,
            rr.id_credito,
            rr.id_modelo,
            rr.fecha_evaluacion,
            rr.score_riesgo,
            rr.probabilidad_incumplimiento,
            rr.severidad_perdida,
            rr.exposicion_incumplimiento,
            rr.perdida_esperada,
            rr.clasificacion_riesgo,
            rr.semaforo,
            rr.dictamen,
            rr.explicacion,
            rr.detalle_resultado,
            rr.fecha_creacion,
            row_number() OVER (PARTITION BY rr.id_credito ORDER BY rr.fecha_evaluacion DESC, rr.id_resultado DESC) AS rn
           FROM siarc.tb_resultado_riesgo rr
        )
 SELECT id_resultado,
    id_credito,
    id_modelo,
    fecha_evaluacion,
    score_riesgo,
    probabilidad_incumplimiento AS pd,
    severidad_perdida AS lgd,
    exposicion_incumplimiento AS ead,
    perdida_esperada,
    clasificacion_riesgo,
    semaforo,
    dictamen,
    explicacion,
    detalle_resultado
   FROM ultimo
  WHERE (rn = 1);


--
-- Name: mv_riesgo_cartera; Type: MATERIALIZED VIEW; Schema: siarc; Owner: -
--

CREATE MATERIALIZED VIEW siarc.mv_riesgo_cartera AS
 SELECT cr.id_credito,
    cr.codigo_credito_externo,
    cli.id_cliente,
    cli.codigo_cliente_externo,
    cli.nombre_cliente,
    cli.rfc,
    cli.curp,
    cli.tipo_persona,
    cli.actividad_economica,
    cli.estado,
    cli.municipio,
    p.nombre_producto,
    s.nombre_sucursal,
    ec.estado_credito,
    fp.frecuencia_pago,
    cr.fecha_otorgamiento,
    cr.fecha_vencimiento,
    cr.plazo_meses,
    cr.monto_original,
    cr.saldo_actual,
    cr.saldo_capital,
    cr.saldo_interes,
    cr.saldo_moratorio,
    cr.tasa_interes_anual,
    cr.dias_atraso,
    cr.numero_pagos_pactados,
    cr.numero_pagos_realizados,
    cr.fecha_ultimo_pago,
    cr.monto_ultimo_pago,
    cr.reestructurado,
    cr.castigado,
        CASE
            WHEN (cr.monto_original > (0)::numeric) THEN ((cr.monto_original - cr.saldo_actual) / cr.monto_original)
            ELSE (0)::numeric
        END AS porcentaje_amortizado,
        CASE
            WHEN (cr.numero_pagos_pactados > 0) THEN ((cr.numero_pagos_realizados)::numeric / (cr.numero_pagos_pactados)::numeric)
            ELSE (0)::numeric
        END AS avance_pagos,
        CASE
            WHEN (cr.dias_atraso = 0) THEN 'SIN ATRASO'::text
            WHEN ((cr.dias_atraso >= 1) AND (cr.dias_atraso <= 30)) THEN '1-30'::text
            WHEN ((cr.dias_atraso >= 31) AND (cr.dias_atraso <= 60)) THEN '31-60'::text
            WHEN ((cr.dias_atraso >= 61) AND (cr.dias_atraso <= 90)) THEN '61-90'::text
            WHEN ((cr.dias_atraso >= 91) AND (cr.dias_atraso <= 180)) THEN '91-180'::text
            ELSE '180+'::text
        END AS bucket_atraso,
    COALESCE(g.valor_garantia_total, (0)::numeric) AS valor_garantia_total,
    COALESCE(g.valor_recuperable_total, (0)::numeric) AS valor_recuperable_garantia,
        CASE
            WHEN (cr.saldo_actual > (0)::numeric) THEN (COALESCE(g.valor_recuperable_total, (0)::numeric) / cr.saldo_actual)
            ELSE (0)::numeric
        END AS cobertura_garantia,
    ur.fecha_evaluacion,
    ur.score_riesgo,
    ur.pd,
    ur.lgd,
    ur.ead,
    ur.perdida_esperada,
    ur.clasificacion_riesgo,
    ur.semaforo,
    ur.dictamen,
        CASE
            WHEN (ur.perdida_esperada IS NULL) THEN (0)::numeric
            ELSE ur.perdida_esperada
        END AS perdida_esperada_calculada,
        CASE
            WHEN ((cr.saldo_actual > (0)::numeric) AND (ur.perdida_esperada IS NOT NULL)) THEN (ur.perdida_esperada / cr.saldo_actual)
            ELSE (0)::numeric
        END AS perdida_esperada_sobre_saldo,
        CASE
            WHEN ((cr.castigado = true) OR (cr.dias_atraso > 90)) THEN 'ETAPA 3'::text
            WHEN ((cr.reestructurado = true) OR ((cr.dias_atraso >= 31) AND (cr.dias_atraso <= 90))) THEN 'ETAPA 2'::text
            ELSE 'ETAPA 1'::text
        END AS etapa_riesgo_siarc,
        CASE
            WHEN ((cr.castigado = true) OR (cr.dias_atraso > 90)) THEN 'DETERIORADO'::text
            WHEN ((cr.dias_atraso >= 31) AND (cr.dias_atraso <= 90)) THEN 'RIESGO SIGNIFICATIVO'::text
            WHEN ((cr.dias_atraso >= 1) AND (cr.dias_atraso <= 30)) THEN 'VIGILANCIA'::text
            ELSE 'NORMAL'::text
        END AS clasificacion_cartera_siarc,
        CASE
            WHEN ((cr.castigado = true) OR (cr.dias_atraso > 90)) THEN (cr.saldo_actual * 0.60)
            WHEN ((cr.dias_atraso >= 61) AND (cr.dias_atraso <= 90)) THEN (cr.saldo_actual * 0.35)
            WHEN ((cr.dias_atraso >= 31) AND (cr.dias_atraso <= 60)) THEN (cr.saldo_actual * 0.15)
            WHEN ((cr.dias_atraso >= 1) AND (cr.dias_atraso <= 30)) THEN (cr.saldo_actual * 0.05)
            ELSE (cr.saldo_actual * 0.01)
        END AS reserva_estimada_siarc,
    CURRENT_TIMESTAMP AS fecha_generacion
   FROM (((((((siarc.tb_credito cr
     LEFT JOIN siarc.tb_cliente cli ON ((cr.id_cliente = cli.id_cliente)))
     LEFT JOIN siarc.cat_producto p ON ((cr.id_producto = p.id_producto)))
     LEFT JOIN siarc.cat_sucursal s ON ((cr.id_sucursal = s.id_sucursal)))
     LEFT JOIN siarc.cat_estado_credito ec ON ((cr.id_estado_credito = ec.id_estado_credito)))
     LEFT JOIN siarc.cat_frecuencia_pago fp ON ((cr.id_frecuencia_pago = fp.id_frecuencia_pago)))
     LEFT JOIN siarc.vw_ultimo_riesgo_credito ur ON ((cr.id_credito = ur.id_credito)))
     LEFT JOIN ( SELECT tb_garantia.id_credito,
            sum(tb_garantia.valor_garantia) AS valor_garantia_total,
            sum(tb_garantia.valor_recuperable_estimado) AS valor_recuperable_total
           FROM siarc.tb_garantia
          WHERE (tb_garantia.activo = true)
          GROUP BY tb_garantia.id_credito) g ON ((cr.id_credito = g.id_credito)))
  WITH NO DATA;


--
-- Name: mv_dataset_ia_pd; Type: MATERIALIZED VIEW; Schema: siarc; Owner: -
--

CREATE MATERIALIZED VIEW siarc.mv_dataset_ia_pd AS
 SELECT id_credito,
    nombre_cliente,
    nombre_producto,
    nombre_sucursal,
    estado,
    municipio,
    monto_original,
    saldo_actual,
    tasa_interes_anual,
    plazo_meses,
    dias_atraso,
    numero_pagos_pactados,
    numero_pagos_realizados,
    porcentaje_amortizado,
    avance_pagos,
    cobertura_garantia,
        CASE
            WHEN reestructurado THEN 1
            ELSE 0
        END AS reestructurado,
        CASE
            WHEN castigado THEN 1
            ELSE 0
        END AS castigado,
    score_riesgo,
    pd AS pd_reglas,
    lgd,
    ead,
    perdida_esperada,
        CASE
            WHEN (castigado = true) THEN 1
            WHEN (dias_atraso > 90) THEN 1
            WHEN (semaforo = 'ROJO'::text) THEN 1
            ELSE 0
        END AS incumplio
   FROM siarc.mv_riesgo_cartera
  WHERE (saldo_actual > (0)::numeric)
  WITH NO DATA;


--
-- Name: tb_alerta_temprana; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_alerta_temprana (
    id_alerta integer NOT NULL,
    id_credito integer NOT NULL,
    id_resultado integer,
    fecha_alerta date DEFAULT CURRENT_DATE,
    tipo_alerta text NOT NULL,
    nivel_alerta text,
    descripcion text,
    recomendacion text,
    atendida boolean DEFAULT false,
    fecha_atencion timestamp without time zone,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT tb_alerta_temprana_nivel_alerta_check CHECK ((nivel_alerta = ANY (ARRAY['BAJO'::text, 'MEDIO'::text, 'ALTO'::text, 'CRITICO'::text])))
);


--
-- Name: TABLE tb_alerta_temprana; Type: COMMENT; Schema: siarc; Owner: -
--

COMMENT ON TABLE siarc.tb_alerta_temprana IS 'Alertas preventivas de deterioro de cartera.';


--
-- Name: tb_alerta_temprana_id_alerta_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_alerta_temprana_id_alerta_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_alerta_temprana_id_alerta_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_alerta_temprana_id_alerta_seq OWNED BY siarc.tb_alerta_temprana.id_alerta;


--
-- Name: tb_analisis_credito; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_analisis_credito (
    id_analisis integer NOT NULL,
    id_solicitud integer NOT NULL,
    fecha_analisis timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    ingreso_mensual numeric(18,2),
    egreso_mensual numeric(18,2),
    ingreso_disponible numeric(18,2),
    monto_solicitado numeric(18,2),
    plazo_meses integer,
    tasa_interes_anual numeric(10,4),
    pago_estimado_mensual numeric(18,2),
    relacion_pago_ingreso numeric(10,4),
    valor_garantia numeric(18,2),
    cobertura_garantia numeric(10,4),
    score_capacidad_pago numeric(10,4),
    score_garantia numeric(10,4),
    score_plazo numeric(10,4),
    score_final numeric(10,4),
    pd_estimada numeric(10,8),
    lgd_estimada numeric(10,8),
    ead_estimada numeric(18,2),
    perdida_esperada_estimada numeric(18,2),
    semaforo character varying(20),
    nivel_riesgo character varying(30),
    monto_recomendado numeric(18,2),
    dictamen text,
    analista character varying(100),
    observaciones text
);


--
-- Name: tb_analisis_credito_id_analisis_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_analisis_credito_id_analisis_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_analisis_credito_id_analisis_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_analisis_credito_id_analisis_seq OWNED BY siarc.tb_analisis_credito.id_analisis;


--
-- Name: tb_api_key; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_api_key (
    id_api_key integer NOT NULL,
    nombre_sistema character varying(100) NOT NULL,
    api_key character varying(200) NOT NULL,
    activa boolean DEFAULT true,
    permisos jsonb,
    fecha_alta timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    fecha_baja timestamp without time zone
);


--
-- Name: tb_api_key_id_api_key_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_api_key_id_api_key_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_api_key_id_api_key_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_api_key_id_api_key_seq OWNED BY siarc.tb_api_key.id_api_key;


--
-- Name: tb_api_log; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_api_log (
    id_log integer NOT NULL,
    fecha timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    nombre_sistema character varying(100),
    api_key character varying(200),
    endpoint text,
    metodo character varying(20),
    ip_cliente text,
    estatus character varying(20),
    detalle text
);


--
-- Name: tb_api_log_id_log_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_api_log_id_log_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_api_log_id_log_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_api_log_id_log_seq OWNED BY siarc.tb_api_log.id_log;


--
-- Name: tb_bitacora_auditoria; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_bitacora_auditoria (
    id_evento integer NOT NULL,
    fecha_evento timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    usuario character varying(100),
    modulo character varying(100),
    accion character varying(100),
    referencia character varying(150),
    descripcion text,
    datos_adicionales jsonb
);


--
-- Name: tb_bitacora_auditoria_id_evento_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_bitacora_auditoria_id_evento_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_bitacora_auditoria_id_evento_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_bitacora_auditoria_id_evento_seq OWNED BY siarc.tb_bitacora_auditoria.id_evento;


--
-- Name: tb_clasificacion_cartera; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_clasificacion_cartera (
    id_clasificacion integer NOT NULL,
    id_credito integer NOT NULL,
    id_resultado integer,
    fecha_clasificacion date DEFAULT CURRENT_DATE,
    clasificacion_contable text,
    etapa_riesgo text,
    grado_riesgo text,
    dias_atraso integer,
    saldo_clasificado numeric(18,2),
    reserva_estimada numeric(18,2),
    porcentaje_reserva numeric(10,8),
    motivo_clasificacion text,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_clasificacion_cartera_id_clasificacion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_clasificacion_cartera_id_clasificacion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_clasificacion_cartera_id_clasificacion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_clasificacion_cartera_id_clasificacion_seq OWNED BY siarc.tb_clasificacion_cartera.id_clasificacion;


--
-- Name: tb_cliente_id_cliente_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_cliente_id_cliente_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_cliente_id_cliente_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_cliente_id_cliente_seq OWNED BY siarc.tb_cliente.id_cliente;


--
-- Name: tb_comite_credito; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_comite_credito (
    id_comite integer NOT NULL,
    id_solicitud integer NOT NULL,
    fecha_comite timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    decision character varying(30) NOT NULL,
    monto_aprobado numeric(18,2),
    plazo_aprobado integer,
    tasa_aprobada numeric(10,4),
    condiciones text,
    comentarios text,
    usuario_comite character varying(100)
);


--
-- Name: tb_comite_credito_id_comite_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_comite_credito_id_comite_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_comite_credito_id_comite_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_comite_credito_id_comite_seq OWNED BY siarc.tb_comite_credito.id_comite;


--
-- Name: tb_configuracion_modelo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_configuracion_modelo (
    parametro character varying(100),
    valor numeric(10,4)
);


--
-- Name: tb_credito_calendario; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_credito_calendario (
    id_calendario integer NOT NULL,
    id_credito_originado integer NOT NULL,
    numero_pago integer NOT NULL,
    fecha_vencimiento date NOT NULL,
    saldo_inicial numeric(18,2),
    pago_programado numeric(18,2),
    capital_programado numeric(18,2),
    interes_programado numeric(18,2),
    saldo_final numeric(18,2),
    estatus_pago character varying(30) DEFAULT 'PENDIENTE'::character varying,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_credito_calendario_id_calendario_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_credito_calendario_id_calendario_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_credito_calendario_id_calendario_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_credito_calendario_id_calendario_seq OWNED BY siarc.tb_credito_calendario.id_calendario;


--
-- Name: tb_credito_cobertura_garantia; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_credito_cobertura_garantia (
    id_cobertura integer NOT NULL,
    id_credito_originado integer NOT NULL,
    id_fondo integer NOT NULL,
    porcentaje_cobertura numeric(10,4) NOT NULL,
    monto_base_cobertura numeric(18,2),
    monto_maximo_cubierto numeric(18,2),
    estatus_cobertura character varying(30) DEFAULT 'ACTIVA'::character varying,
    observaciones text,
    fecha_alta timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_credito_cobertura_garantia_id_cobertura_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_credito_cobertura_garantia_id_cobertura_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_credito_cobertura_garantia_id_cobertura_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_credito_cobertura_garantia_id_cobertura_seq OWNED BY siarc.tb_credito_cobertura_garantia.id_cobertura;


--
-- Name: tb_credito_id_credito_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_credito_id_credito_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_credito_id_credito_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_credito_id_credito_seq OWNED BY siarc.tb_credito.id_credito;


--
-- Name: tb_credito_mitigante_riesgo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_credito_mitigante_riesgo (
    id_credito_mitigante integer NOT NULL,
    id_credito_originado integer NOT NULL,
    id_mitigante integer NOT NULL,
    porcentaje_cobertura numeric(10,4) NOT NULL,
    monto_cubierto numeric(18,2),
    observaciones text,
    activo boolean DEFAULT true,
    fecha_registro timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_credito_mitigante_riesgo_id_credito_mitigante_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_credito_mitigante_riesgo_id_credito_mitigante_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_credito_mitigante_riesgo_id_credito_mitigante_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_credito_mitigante_riesgo_id_credito_mitigante_seq OWNED BY siarc.tb_credito_mitigante_riesgo.id_credito_mitigante;


--
-- Name: tb_credito_originado; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_credito_originado (
    id_credito_originado integer NOT NULL,
    id_solicitud integer NOT NULL,
    codigo_credito character varying(50) NOT NULL,
    fecha_formalizacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    nombre_acreditado character varying(250),
    curp character varying(18),
    rfc character varying(13),
    producto character varying(100),
    destino_credito text,
    monto_aprobado numeric(18,2) NOT NULL,
    plazo_meses integer NOT NULL,
    tasa_interes_anual numeric(10,4),
    saldo_inicial numeric(18,2),
    saldo_actual numeric(18,2),
    estatus_credito character varying(30) DEFAULT 'FORMALIZADO'::character varying,
    fecha_actualizacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    fecha_primer_vencimiento date,
    tipo_amortizacion character varying(30) DEFAULT 'FRANCES'::character varying
);


--
-- Name: tb_credito_originado_id_credito_originado_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_credito_originado_id_credito_originado_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_credito_originado_id_credito_originado_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_credito_originado_id_credito_originado_seq OWNED BY siarc.tb_credito_originado.id_credito_originado;


--
-- Name: tb_credito_pago; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_credito_pago (
    id_pago integer NOT NULL,
    id_credito_originado integer NOT NULL,
    id_calendario integer,
    numero_pago integer,
    fecha_pago date NOT NULL,
    importe_pagado numeric(18,2) NOT NULL,
    capital_pagado numeric(18,2),
    interes_pagado numeric(18,2),
    saldo_anterior numeric(18,2),
    saldo_posterior numeric(18,2),
    usuario character varying(100),
    fecha_registro timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    referencia_pago character varying(100),
    canal_pago character varying(50),
    observaciones text
);


--
-- Name: tb_credito_pago_id_pago_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_credito_pago_id_pago_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_credito_pago_id_pago_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_credito_pago_id_pago_seq OWNED BY siarc.tb_credito_pago.id_pago;


--
-- Name: tb_estado_credito_historico; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_estado_credito_historico (
    id_estado integer NOT NULL,
    fecha_corte date,
    id_credito integer,
    estado_markov character varying(5),
    saldo_actual numeric(18,2)
);


--
-- Name: tb_estado_credito_historico_id_estado_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_estado_credito_historico_id_estado_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_estado_credito_historico_id_estado_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_estado_credito_historico_id_estado_seq OWNED BY siarc.tb_estado_credito_historico.id_estado;


--
-- Name: tb_garantia_id_garantia_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_garantia_id_garantia_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_garantia_id_garantia_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_garantia_id_garantia_seq OWNED BY siarc.tb_garantia.id_garantia;


--
-- Name: tb_gestion_cobranza; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_gestion_cobranza (
    id_gestion integer NOT NULL,
    id_credito_originado integer NOT NULL,
    fecha_gestion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    tipo_gestion character varying(50) NOT NULL,
    resultado_gestion character varying(50) NOT NULL,
    comentario text,
    promesa_pago boolean DEFAULT false,
    fecha_promesa_pago date,
    monto_promesa_pago numeric(18,2),
    usuario character varying(100),
    fecha_registro timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_gestion_cobranza_id_gestion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_gestion_cobranza_id_gestion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_gestion_cobranza_id_gestion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_gestion_cobranza_id_gestion_seq OWNED BY siarc.tb_gestion_cobranza.id_gestion;


--
-- Name: tb_log_acceso; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_log_acceso (
    id_log bigint NOT NULL,
    fecha_evento timestamp without time zone DEFAULT now() NOT NULL,
    usuario character varying(100),
    rol character varying(50),
    ip_origen character varying(100),
    evento character varying(100),
    descripcion text
);


--
-- Name: tb_log_acceso_id_log_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_log_acceso_id_log_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_log_acceso_id_log_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_log_acceso_id_log_seq OWNED BY siarc.tb_log_acceso.id_log;


--
-- Name: tb_map_cliente; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_map_cliente (
    id_map integer NOT NULL,
    id_mifos_cliente bigint,
    id_cliente integer,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_map_cliente_id_map_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_map_cliente_id_map_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_map_cliente_id_map_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_map_cliente_id_map_seq OWNED BY siarc.tb_map_cliente.id_map;


--
-- Name: tb_map_credito; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_map_credito (
    id_map integer NOT NULL,
    id_mifos_credito bigint,
    id_credito integer,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_map_credito_id_map_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_map_credito_id_map_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_map_credito_id_map_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_map_credito_id_map_seq OWNED BY siarc.tb_map_credito.id_map;


--
-- Name: tb_markov_historico; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_markov_historico (
    id_historico integer NOT NULL,
    fecha_corte date,
    id_credito integer,
    estado_markov character varying(5),
    saldo_actual numeric(18,2),
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_markov_historico_id_historico_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_markov_historico_id_historico_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_markov_historico_id_historico_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_markov_historico_id_historico_seq OWNED BY siarc.tb_markov_historico.id_historico;


--
-- Name: tb_matriz_markov_base; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_matriz_markov_base (
    estado_origen character varying(5),
    estado_destino character varying(5),
    probabilidad numeric(10,8)
);


--
-- Name: tb_matriz_markov_calculada; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_matriz_markov_calculada (
    id_matriz integer NOT NULL,
    fecha_calculo timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    estado_origen character varying(5),
    estado_destino character varying(5),
    total_movimientos integer,
    probabilidad numeric(10,8),
    fuente text DEFAULT 'HISTORICO_CARTERA'::text
);


--
-- Name: tb_matriz_markov_calculada_id_matriz_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_matriz_markov_calculada_id_matriz_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_matriz_markov_calculada_id_matriz_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_matriz_markov_calculada_id_matriz_seq OWNED BY siarc.tb_matriz_markov_calculada.id_matriz;


--
-- Name: tb_matriz_transicion; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_matriz_transicion (
    id_transicion integer NOT NULL,
    id_modelo integer,
    fecha_calculo date DEFAULT CURRENT_DATE,
    estado_origen text NOT NULL,
    estado_destino text NOT NULL,
    probabilidad numeric(10,8) NOT NULL,
    periodo_meses integer DEFAULT 1,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT tb_matriz_transicion_probabilidad_check CHECK (((probabilidad >= (0)::numeric) AND (probabilidad <= (1)::numeric)))
);


--
-- Name: tb_matriz_transicion_id_transicion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_matriz_transicion_id_transicion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_matriz_transicion_id_transicion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_matriz_transicion_id_transicion_seq OWNED BY siarc.tb_matriz_transicion.id_transicion;


--
-- Name: tb_mifos_cliente; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_mifos_cliente (
    id_mifos_cliente bigint NOT NULL,
    display_name text,
    office_id bigint,
    office_name text,
    status text,
    external_id text,
    activation_date date,
    json_completo jsonb,
    fecha_sync timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_mifos_credito; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_mifos_credito (
    id_mifos_credito bigint NOT NULL,
    id_mifos_cliente bigint,
    account_no text,
    product_name text,
    loan_status text,
    principal_amount numeric(18,2),
    approved_amount numeric(18,2),
    disbursed_amount numeric(18,2),
    outstanding_balance numeric(18,2),
    overdue_amount numeric(18,2),
    days_in_arrears integer,
    disbursement_date date,
    maturity_date date,
    json_completo jsonb,
    fecha_sync timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_mifos_pago; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_mifos_pago (
    id_pago integer NOT NULL,
    id_mifos_credito bigint,
    transaction_id bigint,
    transaction_date date,
    amount numeric(18,2),
    principal_portion numeric(18,2),
    interest_portion numeric(18,2),
    penalty_portion numeric(18,2),
    json_completo jsonb,
    fecha_sync timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_mifos_pago_id_pago_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_mifos_pago_id_pago_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_mifos_pago_id_pago_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_mifos_pago_id_pago_seq OWNED BY siarc.tb_mifos_pago.id_pago;


--
-- Name: tb_modelo_riesgo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_modelo_riesgo (
    id_modelo integer NOT NULL,
    nombre_modelo text NOT NULL,
    tipo_modelo text NOT NULL,
    version_modelo text DEFAULT '1.0'::text,
    descripcion text,
    fecha_inicio_vigencia date DEFAULT CURRENT_DATE,
    fecha_fin_vigencia date,
    activo boolean DEFAULT true,
    parametros jsonb,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_modelo_riesgo_id_modelo_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_modelo_riesgo_id_modelo_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_modelo_riesgo_id_modelo_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_modelo_riesgo_id_modelo_seq OWNED BY siarc.tb_modelo_riesgo.id_modelo;


--
-- Name: tb_modelo_variable; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_modelo_variable (
    id_modelo_variable integer NOT NULL,
    id_modelo integer NOT NULL,
    id_variable integer NOT NULL,
    peso numeric(18,6),
    obligatorio boolean DEFAULT true,
    parametros jsonb
);


--
-- Name: tb_modelo_variable_id_modelo_variable_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_modelo_variable_id_modelo_variable_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_modelo_variable_id_modelo_variable_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_modelo_variable_id_modelo_variable_seq OWNED BY siarc.tb_modelo_variable.id_modelo_variable;


--
-- Name: tb_monte_carlo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_monte_carlo (
    id_simulacion integer NOT NULL,
    id_modelo integer,
    fecha_simulacion date DEFAULT CURRENT_DATE,
    numero_escenarios integer,
    horizonte_meses integer,
    perdida_promedio numeric(18,2),
    perdida_percentil_95 numeric(18,2),
    perdida_percentil_99 numeric(18,2),
    perdida_maxima numeric(18,2),
    parametros jsonb,
    resultado_detallado jsonb,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_monte_carlo_id_simulacion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_monte_carlo_id_simulacion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_monte_carlo_id_simulacion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_monte_carlo_id_simulacion_seq OWNED BY siarc.tb_monte_carlo.id_simulacion;


--
-- Name: tb_montecarlo_cartera; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_montecarlo_cartera (
    id_simulacion integer NOT NULL,
    fecha_simulacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    numero_escenarios integer,
    perdida_promedio numeric(18,2),
    perdida_minima numeric(18,2),
    perdida_maxima numeric(18,2),
    var_95 numeric(18,2),
    var_99 numeric(18,2),
    perdida_esperada_base numeric(18,2),
    perdida_inesperada_95 numeric(18,2),
    perdida_inesperada_99 numeric(18,2)
);


--
-- Name: tb_montecarlo_cartera_id_simulacion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_montecarlo_cartera_id_simulacion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_montecarlo_cartera_id_simulacion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_montecarlo_cartera_id_simulacion_seq OWNED BY siarc.tb_montecarlo_cartera.id_simulacion;


--
-- Name: tb_montecarlo_escenario; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_montecarlo_escenario (
    id_escenario integer NOT NULL,
    id_simulacion integer,
    numero_escenario integer,
    perdida_total numeric(18,2)
);


--
-- Name: tb_montecarlo_escenario_id_escenario_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_montecarlo_escenario_id_escenario_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_montecarlo_escenario_id_escenario_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_montecarlo_escenario_id_escenario_seq OWNED BY siarc.tb_montecarlo_escenario.id_escenario;


--
-- Name: tb_montecarlo_ia_cartera; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_montecarlo_ia_cartera (
    id_simulacion integer NOT NULL,
    fecha_simulacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    numero_escenarios integer,
    perdida_promedio numeric(18,2),
    perdida_minima numeric(18,2),
    perdida_maxima numeric(18,2),
    var_95 numeric(18,2),
    var_99 numeric(18,2),
    perdida_esperada_ia_base numeric(18,2),
    perdida_inesperada_95 numeric(18,2),
    perdida_inesperada_99 numeric(18,2)
);


--
-- Name: tb_montecarlo_ia_cartera_id_simulacion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_montecarlo_ia_cartera_id_simulacion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_montecarlo_ia_cartera_id_simulacion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_montecarlo_ia_cartera_id_simulacion_seq OWNED BY siarc.tb_montecarlo_ia_cartera.id_simulacion;


--
-- Name: tb_montecarlo_ia_escenario; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_montecarlo_ia_escenario (
    id_escenario integer NOT NULL,
    id_simulacion integer,
    numero_escenario integer,
    perdida_total numeric(18,2)
);


--
-- Name: tb_montecarlo_ia_escenario_id_escenario_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_montecarlo_ia_escenario_id_escenario_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_montecarlo_ia_escenario_id_escenario_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_montecarlo_ia_escenario_id_escenario_seq OWNED BY siarc.tb_montecarlo_ia_escenario.id_escenario;


--
-- Name: tb_pago; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_pago (
    id_pago integer NOT NULL,
    codigo_pago_externo character varying(100),
    id_credito integer NOT NULL,
    fecha_pago date NOT NULL,
    fecha_aplicacion date,
    monto_pago numeric(16,2) NOT NULL,
    capital_pagado numeric(16,2) DEFAULT 0,
    interes_pagado numeric(16,2) DEFAULT 0,
    moratorio_pagado numeric(16,2) DEFAULT 0,
    otros_cargos_pagados numeric(16,2) DEFAULT 0,
    saldo_despues_pago numeric(16,2),
    medio_pago text,
    referencia_pago text,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT tb_pago_monto_pago_check CHECK ((monto_pago >= (0)::numeric))
);


--
-- Name: TABLE tb_pago; Type: COMMENT; Schema: siarc; Owner: -
--

COMMENT ON TABLE siarc.tb_pago IS 'Pagos realizados por crédito.';


--
-- Name: tb_pago_garantia_fondo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_pago_garantia_fondo (
    id_pago_garantia integer NOT NULL,
    id_reclamacion integer NOT NULL,
    fecha_pago timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    monto_pagado_fondo numeric(18,2) NOT NULL,
    referencia_pago character varying(100),
    observaciones text
);


--
-- Name: tb_pago_garantia_fondo_id_pago_garantia_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_pago_garantia_fondo_id_pago_garantia_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_pago_garantia_fondo_id_pago_garantia_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_pago_garantia_fondo_id_pago_garantia_seq OWNED BY siarc.tb_pago_garantia_fondo.id_pago_garantia;


--
-- Name: tb_pago_id_pago_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_pago_id_pago_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_pago_id_pago_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_pago_id_pago_seq OWNED BY siarc.tb_pago.id_pago;


--
-- Name: tb_perdida_esperada; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_perdida_esperada (
    id_perdida integer NOT NULL,
    id_credito integer NOT NULL,
    id_resultado integer,
    fecha_calculo date DEFAULT CURRENT_DATE,
    ead numeric(18,2) NOT NULL,
    pd numeric(10,8) NOT NULL,
    lgd numeric(10,8) NOT NULL,
    perdida_esperada numeric(18,2) GENERATED ALWAYS AS (((ead * pd) * lgd)) STORED,
    escenario text DEFAULT 'BASE'::text,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT tb_perdida_esperada_lgd_check CHECK (((lgd >= (0)::numeric) AND (lgd <= (1)::numeric))),
    CONSTRAINT tb_perdida_esperada_pd_check CHECK (((pd >= (0)::numeric) AND (pd <= (1)::numeric)))
);


--
-- Name: TABLE tb_perdida_esperada; Type: COMMENT; Schema: siarc; Owner: -
--

COMMENT ON TABLE siarc.tb_perdida_esperada IS 'Cálculo detallado de pérdida esperada: EAD x PD x LGD.';


--
-- Name: tb_perdida_esperada_id_perdida_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_perdida_esperada_id_perdida_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_perdida_esperada_id_perdida_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_perdida_esperada_id_perdida_seq OWNED BY siarc.tb_perdida_esperada.id_perdida;


--
-- Name: tb_poliza_contable; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_poliza_contable (
    id_poliza integer NOT NULL,
    fecha_poliza timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    clave_evento character varying(50) NOT NULL,
    referencia character varying(100),
    descripcion text,
    origen_modulo character varying(100),
    estatus character varying(30) DEFAULT 'GENERADA'::character varying,
    fecha_registro timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_poliza_contable_id_poliza_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_poliza_contable_id_poliza_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_poliza_contable_id_poliza_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_poliza_contable_id_poliza_seq OWNED BY siarc.tb_poliza_contable.id_poliza;


--
-- Name: tb_poliza_detalle; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_poliza_detalle (
    id_detalle integer NOT NULL,
    id_poliza integer NOT NULL,
    cuenta character varying(30) NOT NULL,
    descripcion text,
    cargo numeric(18,2) DEFAULT 0,
    abono numeric(18,2) DEFAULT 0
);


--
-- Name: tb_poliza_detalle_id_detalle_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_poliza_detalle_id_detalle_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_poliza_detalle_id_detalle_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_poliza_detalle_id_detalle_seq OWNED BY siarc.tb_poliza_detalle.id_detalle;


--
-- Name: tb_proyeccion_markov; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_proyeccion_markov (
    id_proyeccion integer NOT NULL,
    fecha_proyeccion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    horizonte_meses integer NOT NULL,
    estado_markov character varying(5) NOT NULL,
    creditos_esperados numeric(18,6),
    saldo_esperado numeric(18,2)
);


--
-- Name: tb_proyeccion_markov_ia; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_proyeccion_markov_ia (
    id_proyeccion integer NOT NULL,
    fecha_proyeccion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    horizonte_meses integer NOT NULL,
    estado_markov character varying(5) NOT NULL,
    creditos_esperados numeric(18,6),
    saldo_esperado numeric(18,2)
);


--
-- Name: tb_proyeccion_markov_ia_id_proyeccion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_proyeccion_markov_ia_id_proyeccion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_proyeccion_markov_ia_id_proyeccion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_proyeccion_markov_ia_id_proyeccion_seq OWNED BY siarc.tb_proyeccion_markov_ia.id_proyeccion;


--
-- Name: tb_proyeccion_markov_id_proyeccion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_proyeccion_markov_id_proyeccion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_proyeccion_markov_id_proyeccion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_proyeccion_markov_id_proyeccion_seq OWNED BY siarc.tb_proyeccion_markov.id_proyeccion;


--
-- Name: tb_reclamacion_garantia; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_reclamacion_garantia (
    id_reclamacion integer NOT NULL,
    id_cobertura integer NOT NULL,
    fecha_reclamacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    saldo_reclamado numeric(18,2) NOT NULL,
    porcentaje_cobertura numeric(10,4) NOT NULL,
    monto_reclamado_fondo numeric(18,2) NOT NULL,
    monto_a_cargo_institucion numeric(18,2) NOT NULL,
    estatus_reclamacion character varying(30) DEFAULT 'RECLAMADA'::character varying,
    observaciones text
);


--
-- Name: tb_reclamacion_garantia_id_reclamacion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_reclamacion_garantia_id_reclamacion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_reclamacion_garantia_id_reclamacion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_reclamacion_garantia_id_reclamacion_seq OWNED BY siarc.tb_reclamacion_garantia.id_reclamacion;


--
-- Name: tb_recuperacion_post_garantia; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_recuperacion_post_garantia (
    id_recuperacion integer NOT NULL,
    id_reclamacion integer NOT NULL,
    fecha_recuperacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    monto_recuperado numeric(18,2) NOT NULL,
    porcentaje_fondo numeric(10,4) NOT NULL,
    monto_para_fondo numeric(18,2) NOT NULL,
    monto_para_institucion numeric(18,2) NOT NULL,
    referencia_recuperacion character varying(100),
    observaciones text
);


--
-- Name: tb_recuperacion_post_garantia_id_recuperacion_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_recuperacion_post_garantia_id_recuperacion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_recuperacion_post_garantia_id_recuperacion_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_recuperacion_post_garantia_id_recuperacion_seq OWNED BY siarc.tb_recuperacion_post_garantia.id_recuperacion;


--
-- Name: tb_resultado_ia_pd; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_resultado_ia_pd (
    id_resultado integer NOT NULL,
    fecha_calculo timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    id_credito integer,
    pd_reglas numeric(10,8),
    pd_ia numeric(10,8),
    pd_final numeric(10,8),
    modelo character varying(100),
    version_modelo character varying(20)
);


--
-- Name: tb_resultado_ia_pd_id_resultado_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_resultado_ia_pd_id_resultado_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_resultado_ia_pd_id_resultado_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_resultado_ia_pd_id_resultado_seq OWNED BY siarc.tb_resultado_ia_pd.id_resultado;


--
-- Name: tb_resultado_riesgo_id_resultado_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_resultado_riesgo_id_resultado_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_resultado_riesgo_id_resultado_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_resultado_riesgo_id_resultado_seq OWNED BY siarc.tb_resultado_riesgo.id_resultado;


--
-- Name: tb_resultado_variable; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_resultado_variable (
    id_resultado_variable integer NOT NULL,
    id_resultado integer NOT NULL,
    id_variable integer NOT NULL,
    valor_original numeric(18,6),
    valor_normalizado numeric(18,6),
    contribucion_score numeric(18,6),
    observacion text
);


--
-- Name: tb_resultado_variable_id_resultado_variable_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_resultado_variable_id_resultado_variable_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_resultado_variable_id_resultado_variable_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_resultado_variable_id_resultado_variable_seq OWNED BY siarc.tb_resultado_variable.id_resultado_variable;


--
-- Name: tb_snapshot_cartera; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_snapshot_cartera (
    id_snapshot integer NOT NULL,
    fecha_snapshot date DEFAULT CURRENT_DATE,
    total_creditos integer,
    creditos_con_saldo integer,
    creditos_con_atraso integer,
    creditos_sin_atraso integer,
    monto_original_total numeric(18,2),
    saldo_total numeric(18,2),
    saldo_vigente_total numeric(18,2),
    saldo_vencido_total numeric(18,2),
    imor numeric(18,8),
    pd_promedio numeric(18,8),
    lgd_promedio numeric(18,8),
    ead_total numeric(18,2),
    perdida_esperada_total numeric(18,2),
    perdida_esperada_sobre_cartera numeric(18,8),
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_snapshot_cartera_id_snapshot_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_snapshot_cartera_id_snapshot_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_snapshot_cartera_id_snapshot_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_snapshot_cartera_id_snapshot_seq OWNED BY siarc.tb_snapshot_cartera.id_snapshot;


--
-- Name: tb_solicitud_credito; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_solicitud_credito (
    id_solicitud integer NOT NULL,
    folio_solicitud character varying(50) NOT NULL,
    fecha_solicitud timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    nombre character varying(150) NOT NULL,
    paterno character varying(100),
    materno character varying(100),
    curp character varying(18),
    rfc character varying(13),
    telefono character varying(20),
    correo character varying(150),
    estado character varying(100),
    municipio character varying(100),
    localidad character varying(150),
    domicilio text,
    actividad_economica character varying(150),
    ingresos_mensuales numeric(18,2),
    egresos_mensuales numeric(18,2),
    producto_solicitado character varying(100),
    destino_credito text,
    monto_solicitado numeric(18,2) NOT NULL,
    plazo_meses integer NOT NULL,
    tasa_interes_anual numeric(10,4),
    tipo_garantia character varying(100),
    valor_garantia numeric(18,2),
    estatus character varying(30) DEFAULT 'CAPTURADA'::character varying,
    score_preliminar numeric(10,4),
    semaforo_preliminar character varying(20),
    monto_recomendado numeric(18,2),
    dictamen_preliminar text,
    fecha_actualizacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    clave_producto character varying(50),
    clave_actividad character varying(50),
    clave_destino character varying(50),
    clave_tipo_garantia character varying(50)
);


--
-- Name: tb_solicitud_credito_id_solicitud_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_solicitud_credito_id_solicitud_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_solicitud_credito_id_solicitud_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_solicitud_credito_id_solicitud_seq OWNED BY siarc.tb_solicitud_credito.id_solicitud;


--
-- Name: tb_solicitud_historial; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_solicitud_historial (
    id_historial integer NOT NULL,
    id_solicitud integer,
    fecha_evento timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    estatus_anterior character varying(30),
    estatus_nuevo character varying(30),
    comentario text,
    usuario character varying(100)
);


--
-- Name: tb_solicitud_historial_id_historial_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_solicitud_historial_id_historial_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_solicitud_historial_id_historial_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_solicitud_historial_id_historial_seq OWNED BY siarc.tb_solicitud_historial.id_historial;


--
-- Name: tb_stress_test; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_stress_test (
    id_stress integer NOT NULL,
    id_modelo integer,
    fecha_ejecucion date DEFAULT CURRENT_DATE,
    escenario text NOT NULL,
    factor_pd numeric(10,6) DEFAULT 1,
    factor_lgd numeric(10,6) DEFAULT 1,
    factor_ead numeric(10,6) DEFAULT 1,
    perdida_esperada_base numeric(18,2),
    perdida_esperada_estresada numeric(18,2),
    impacto numeric(18,2),
    parametros jsonb,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_stress_test_id_stress_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_stress_test_id_stress_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_stress_test_id_stress_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_stress_test_id_stress_seq OWNED BY siarc.tb_stress_test.id_stress;


--
-- Name: tb_sync_error; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_sync_error (
    id_error integer NOT NULL,
    fecha_error timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    entidad text,
    identificador text,
    descripcion_error text,
    json_error jsonb
);


--
-- Name: tb_sync_error_id_error_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_sync_error_id_error_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_sync_error_id_error_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_sync_error_id_error_seq OWNED BY siarc.tb_sync_error.id_error;


--
-- Name: tb_sync_proceso; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_sync_proceso (
    id_sync integer NOT NULL,
    fecha_inicio timestamp without time zone,
    fecha_fin timestamp without time zone,
    proceso character varying(100),
    registros_leidos integer,
    registros_insertados integer,
    registros_actualizados integer,
    errores integer,
    estatus character varying(50),
    observaciones text
);


--
-- Name: tb_sync_proceso_id_sync_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_sync_proceso_id_sync_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_sync_proceso_id_sync_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_sync_proceso_id_sync_seq OWNED BY siarc.tb_sync_proceso.id_sync;


--
-- Name: tb_usuario; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_usuario (
    id_usuario integer NOT NULL,
    usuario character varying(50) NOT NULL,
    password_hash text NOT NULL,
    nombre character varying(150) NOT NULL,
    correo character varying(150),
    rol character varying(30) DEFAULT 'OPERADOR'::character varying NOT NULL,
    activo boolean DEFAULT true,
    fecha_alta timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_usuario_id_usuario_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_usuario_id_usuario_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_usuario_id_usuario_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_usuario_id_usuario_seq OWNED BY siarc.tb_usuario.id_usuario;


--
-- Name: tb_variable_riesgo; Type: TABLE; Schema: siarc; Owner: -
--

CREATE TABLE siarc.tb_variable_riesgo (
    id_variable integer NOT NULL,
    nombre_variable text NOT NULL,
    descripcion text,
    tipo_variable text,
    unidad_medida text,
    valor_minimo numeric(18,6),
    valor_maximo numeric(18,6),
    activo boolean DEFAULT true,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: tb_variable_riesgo_id_variable_seq; Type: SEQUENCE; Schema: siarc; Owner: -
--

CREATE SEQUENCE siarc.tb_variable_riesgo_id_variable_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tb_variable_riesgo_id_variable_seq; Type: SEQUENCE OWNED BY; Schema: siarc; Owner: -
--

ALTER SEQUENCE siarc.tb_variable_riesgo_id_variable_seq OWNED BY siarc.tb_variable_riesgo.id_variable;


--
-- Name: vw_cartera_base; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_cartera_base AS
 SELECT c.id_credito,
    c.codigo_credito_externo,
    cli.id_cliente,
    cli.codigo_cliente_externo,
    cli.nombre_cliente,
    cli.rfc,
    cli.curp,
    cli.tipo_persona,
    cli.estado,
    cli.municipio,
    cli.actividad_economica,
    p.nombre_producto,
    s.nombre_sucursal,
    ec.estado_credito,
    fp.frecuencia_pago,
    c.fecha_otorgamiento,
    c.fecha_vencimiento,
    c.plazo_meses,
    c.monto_original,
    c.saldo_actual,
    c.saldo_capital,
    c.saldo_interes,
    c.saldo_moratorio,
    c.tasa_interes_anual,
    c.dias_atraso,
    c.numero_pagos_pactados,
    c.numero_pagos_realizados,
    c.fecha_ultimo_pago,
    c.monto_ultimo_pago,
    c.reestructurado,
    c.castigado,
        CASE
            WHEN (c.dias_atraso = 0) THEN 'SIN ATRASO'::text
            WHEN ((c.dias_atraso >= 1) AND (c.dias_atraso <= 30)) THEN '1-30'::text
            WHEN ((c.dias_atraso >= 31) AND (c.dias_atraso <= 60)) THEN '31-60'::text
            WHEN ((c.dias_atraso >= 61) AND (c.dias_atraso <= 90)) THEN '61-90'::text
            WHEN ((c.dias_atraso >= 91) AND (c.dias_atraso <= 180)) THEN '91-180'::text
            ELSE '180+'::text
        END AS bucket_atraso,
        CASE
            WHEN (c.dias_atraso > 0) THEN c.saldo_actual
            ELSE (0)::numeric
        END AS saldo_vencido,
        CASE
            WHEN (c.dias_atraso = 0) THEN c.saldo_actual
            ELSE (0)::numeric
        END AS saldo_vigente
   FROM (((((siarc.tb_credito c
     LEFT JOIN siarc.tb_cliente cli ON ((c.id_cliente = cli.id_cliente)))
     LEFT JOIN siarc.cat_producto p ON ((c.id_producto = p.id_producto)))
     LEFT JOIN siarc.cat_sucursal s ON ((c.id_sucursal = s.id_sucursal)))
     LEFT JOIN siarc.cat_estado_credito ec ON ((c.id_estado_credito = ec.id_estado_credito)))
     LEFT JOIN siarc.cat_frecuencia_pago fp ON ((c.id_frecuencia_pago = fp.id_frecuencia_pago)));


--
-- Name: vw_alertas_activas; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_alertas_activas AS
 SELECT a.id_alerta,
    a.id_credito,
    cb.nombre_cliente,
    cb.codigo_credito_externo,
    cb.nombre_producto,
    cb.estado,
    cb.municipio,
    cb.saldo_actual,
    cb.dias_atraso,
    a.fecha_alerta,
    a.tipo_alerta,
    a.nivel_alerta,
    a.descripcion,
    a.recomendacion,
    a.atendida
   FROM (siarc.tb_alerta_temprana a
     LEFT JOIN siarc.vw_cartera_base cb ON ((a.id_credito = cb.id_credito)))
  WHERE (a.atendida = false);


--
-- Name: vw_analisis_solicitudes; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_analisis_solicitudes AS
 SELECT s.id_solicitud,
    s.folio_solicitud,
    s.fecha_solicitud,
    (((((s.nombre)::text || ' '::text) || (COALESCE(s.paterno, ''::character varying))::text) || ' '::text) || (COALESCE(s.materno, ''::character varying))::text) AS solicitante,
    s.curp,
    s.rfc,
    s.estado,
    s.municipio,
    s.actividad_economica,
    s.monto_solicitado,
    s.plazo_meses,
    s.estatus,
    a.fecha_analisis,
    a.ingreso_mensual,
    a.egreso_mensual,
    a.ingreso_disponible,
    a.tasa_interes_anual,
    a.pago_estimado_mensual,
    a.relacion_pago_ingreso,
    a.valor_garantia,
    a.cobertura_garantia,
    a.score_capacidad_pago,
    a.score_garantia,
    a.score_plazo,
    a.score_final,
    a.pd_estimada,
    a.lgd_estimada,
    a.ead_estimada,
    a.perdida_esperada_estimada,
    a.semaforo,
    a.nivel_riesgo,
    a.monto_recomendado,
    a.dictamen,
    a.analista,
    a.observaciones
   FROM (siarc.tb_solicitud_credito s
     LEFT JOIN LATERAL ( SELECT a_1.id_analisis,
            a_1.id_solicitud,
            a_1.fecha_analisis,
            a_1.ingreso_mensual,
            a_1.egreso_mensual,
            a_1.ingreso_disponible,
            a_1.monto_solicitado,
            a_1.plazo_meses,
            a_1.tasa_interes_anual,
            a_1.pago_estimado_mensual,
            a_1.relacion_pago_ingreso,
            a_1.valor_garantia,
            a_1.cobertura_garantia,
            a_1.score_capacidad_pago,
            a_1.score_garantia,
            a_1.score_plazo,
            a_1.score_final,
            a_1.pd_estimada,
            a_1.lgd_estimada,
            a_1.ead_estimada,
            a_1.perdida_esperada_estimada,
            a_1.semaforo,
            a_1.nivel_riesgo,
            a_1.monto_recomendado,
            a_1.dictamen,
            a_1.analista,
            a_1.observaciones
           FROM siarc.tb_analisis_credito a_1
          WHERE (a_1.id_solicitud = s.id_solicitud)
          ORDER BY a_1.fecha_analisis DESC
         LIMIT 1) a ON (true));


--
-- Name: vw_bitacora_reciente; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_bitacora_reciente AS
 SELECT id_evento,
    fecha_evento,
    usuario,
    modulo,
    accion,
    referencia,
    descripcion,
    datos_adicionales
   FROM siarc.tb_bitacora_auditoria
  ORDER BY fecha_evento DESC;


--
-- Name: vw_cartera_riesgo; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_cartera_riesgo AS
 SELECT cb.id_credito,
    cb.codigo_credito_externo,
    cb.id_cliente,
    cb.codigo_cliente_externo,
    cb.nombre_cliente,
    cb.rfc,
    cb.curp,
    cb.tipo_persona,
    cb.estado,
    cb.municipio,
    cb.actividad_economica,
    cb.nombre_producto,
    cb.nombre_sucursal,
    cb.estado_credito,
    cb.frecuencia_pago,
    cb.fecha_otorgamiento,
    cb.fecha_vencimiento,
    cb.plazo_meses,
    cb.monto_original,
    cb.saldo_actual,
    cb.saldo_capital,
    cb.saldo_interes,
    cb.saldo_moratorio,
    cb.tasa_interes_anual,
    cb.dias_atraso,
    cb.numero_pagos_pactados,
    cb.numero_pagos_realizados,
    cb.fecha_ultimo_pago,
    cb.monto_ultimo_pago,
    cb.reestructurado,
    cb.castigado,
    cb.bucket_atraso,
    cb.saldo_vencido,
    cb.saldo_vigente,
    ur.fecha_evaluacion,
    ur.score_riesgo,
    ur.pd,
    ur.lgd,
    ur.ead,
    ur.perdida_esperada,
    ur.clasificacion_riesgo,
    ur.semaforo,
    ur.dictamen,
        CASE
            WHEN (ur.perdida_esperada IS NULL) THEN (0)::numeric
            ELSE ur.perdida_esperada
        END AS perdida_esperada_calculada,
        CASE
            WHEN ((cb.saldo_actual > (0)::numeric) AND (ur.perdida_esperada IS NOT NULL)) THEN (ur.perdida_esperada / cb.saldo_actual)
            ELSE (0)::numeric
        END AS perdida_esperada_sobre_saldo
   FROM (siarc.vw_cartera_base cb
     LEFT JOIN siarc.vw_ultimo_riesgo_credito ur ON ((cb.id_credito = ur.id_credito)));


--
-- Name: vw_bucket_atraso; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_bucket_atraso AS
 SELECT bucket_atraso,
    count(*) AS total_creditos,
    sum(saldo_actual) AS saldo_total,
    sum(saldo_vencido) AS saldo_vencido_total,
    avg(pd) AS pd_promedio,
    sum(perdida_esperada_calculada) AS perdida_esperada_total
   FROM siarc.vw_cartera_riesgo
  GROUP BY bucket_atraso
  ORDER BY
        CASE bucket_atraso
            WHEN 'SIN ATRASO'::text THEN 1
            WHEN '1-30'::text THEN 2
            WHEN '31-60'::text THEN 3
            WHEN '61-90'::text THEN 4
            WHEN '91-180'::text THEN 5
            ELSE 6
        END;


--
-- Name: vw_calendario_creditos; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_calendario_creditos AS
 SELECT c.id_credito_originado,
    c.codigo_credito,
    c.nombre_acreditado,
    c.monto_aprobado,
    c.plazo_meses,
    c.tasa_interes_anual,
    c.tipo_amortizacion,
    cal.numero_pago,
    cal.fecha_vencimiento,
    cal.saldo_inicial,
    cal.pago_programado,
    cal.capital_programado,
    cal.interes_programado,
    cal.saldo_final,
    cal.estatus_pago
   FROM (siarc.tb_credito_originado c
     JOIN siarc.tb_credito_calendario cal ON ((c.id_credito_originado = cal.id_credito_originado)));


--
-- Name: vw_cartera_crediticia; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_cartera_crediticia AS
 WITH cuotas AS (
         SELECT c.id_credito_originado,
            c.codigo_credito,
            c.nombre_acreditado,
            c.curp,
            c.rfc,
            c.producto,
            c.destino_credito,
            c.monto_aprobado,
            c.saldo_actual,
            c.plazo_meses,
            c.tasa_interes_anual,
            c.estatus_credito,
            cal.id_calendario,
            cal.numero_pago,
            cal.fecha_vencimiento,
            cal.pago_programado,
            cal.capital_programado,
            cal.interes_programado,
            cal.estatus_pago,
                CASE
                    WHEN (((cal.estatus_pago)::text = ANY ((ARRAY['PENDIENTE'::character varying, 'PARCIAL'::character varying])::text[])) AND (cal.fecha_vencimiento < CURRENT_DATE)) THEN cal.pago_programado
                    ELSE (0)::numeric
                END AS monto_vencido_cuota,
                CASE
                    WHEN (((cal.estatus_pago)::text = ANY ((ARRAY['PENDIENTE'::character varying, 'PARCIAL'::character varying])::text[])) AND (cal.fecha_vencimiento < CURRENT_DATE)) THEN (CURRENT_DATE - cal.fecha_vencimiento)
                    ELSE 0
                END AS dias_atraso_cuota
           FROM (siarc.tb_credito_originado c
             LEFT JOIN siarc.tb_credito_calendario cal ON ((c.id_credito_originado = cal.id_credito_originado)))
        ), resumen AS (
         SELECT cuotas.id_credito_originado,
            cuotas.codigo_credito,
            cuotas.nombre_acreditado,
            cuotas.curp,
            cuotas.rfc,
            cuotas.producto,
            cuotas.destino_credito,
            cuotas.monto_aprobado,
            cuotas.saldo_actual,
            cuotas.plazo_meses,
            cuotas.tasa_interes_anual,
            cuotas.estatus_credito,
            count(cuotas.id_calendario) AS pagos_programados,
            sum(
                CASE
                    WHEN ((cuotas.estatus_pago)::text = 'PAGADO'::text) THEN 1
                    ELSE 0
                END) AS pagos_realizados,
            sum(
                CASE
                    WHEN ((cuotas.estatus_pago)::text = ANY ((ARRAY['PENDIENTE'::character varying, 'PARCIAL'::character varying])::text[])) THEN 1
                    ELSE 0
                END) AS pagos_pendientes,
            sum(cuotas.monto_vencido_cuota) AS monto_vencido,
            max(cuotas.dias_atraso_cuota) AS dias_atraso,
            min(
                CASE
                    WHEN ((cuotas.estatus_pago)::text = ANY ((ARRAY['PENDIENTE'::character varying, 'PARCIAL'::character varying])::text[])) THEN cuotas.fecha_vencimiento
                    ELSE NULL::date
                END) AS proximo_vencimiento
           FROM cuotas
          GROUP BY cuotas.id_credito_originado, cuotas.codigo_credito, cuotas.nombre_acreditado, cuotas.curp, cuotas.rfc, cuotas.producto, cuotas.destino_credito, cuotas.monto_aprobado, cuotas.saldo_actual, cuotas.plazo_meses, cuotas.tasa_interes_anual, cuotas.estatus_credito
        )
 SELECT id_credito_originado,
    codigo_credito,
    nombre_acreditado,
    curp,
    rfc,
    producto,
    destino_credito,
    monto_aprobado,
    saldo_actual,
    plazo_meses,
    tasa_interes_anual,
    estatus_credito,
    pagos_programados,
    pagos_realizados,
    pagos_pendientes,
    monto_vencido,
    dias_atraso,
    proximo_vencimiento,
        CASE
            WHEN (dias_atraso >= 90) THEN 'ETAPA 3'::text
            WHEN (dias_atraso >= 1) THEN 'ETAPA 2'::text
            ELSE 'ETAPA 1'::text
        END AS etapa_riesgo,
        CASE
            WHEN (dias_atraso >= 90) THEN 'DETERIORADO'::text
            WHEN (dias_atraso >= 1) THEN 'RIESGO SIGNIFICATIVO'::text
            ELSE 'NORMAL'::text
        END AS clasificacion_cartera
   FROM resumen;


--
-- Name: vw_catalogos_credito_resumen; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_catalogos_credito_resumen AS
 SELECT 'PRODUCTOS'::text AS catalogo,
    count(*) AS total,
    sum(
        CASE
            WHEN cat_producto_credito.activo THEN 1
            ELSE 0
        END) AS activos
   FROM siarc.cat_producto_credito
UNION ALL
 SELECT 'ACTIVIDADES'::text AS catalogo,
    count(*) AS total,
    sum(
        CASE
            WHEN cat_actividad_economica.activo THEN 1
            ELSE 0
        END) AS activos
   FROM siarc.cat_actividad_economica
UNION ALL
 SELECT 'GARANTIAS'::text AS catalogo,
    count(*) AS total,
    sum(
        CASE
            WHEN cat_tipo_garantia.activo THEN 1
            ELSE 0
        END) AS activos
   FROM siarc.cat_tipo_garantia
UNION ALL
 SELECT 'DESTINOS'::text AS catalogo,
    count(*) AS total,
    sum(
        CASE
            WHEN cat_destino_credito.activo THEN 1
            ELSE 0
        END) AS activos
   FROM siarc.cat_destino_credito;


--
-- Name: vw_cnbv_riesgo; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_cnbv_riesgo AS
 SELECT m.id_credito,
    m.codigo_credito_externo,
    m.id_cliente,
    m.codigo_cliente_externo,
    m.nombre_cliente,
    m.rfc,
    m.curp,
    m.tipo_persona,
    m.actividad_economica,
    m.estado,
    m.municipio,
    m.nombre_producto,
    m.nombre_sucursal,
    m.estado_credito,
    m.frecuencia_pago,
    m.fecha_otorgamiento,
    m.fecha_vencimiento,
    m.plazo_meses,
    m.monto_original,
    m.saldo_actual,
    m.saldo_capital,
    m.saldo_interes,
    m.saldo_moratorio,
    m.tasa_interes_anual,
    m.dias_atraso,
    m.numero_pagos_pactados,
    m.numero_pagos_realizados,
    m.fecha_ultimo_pago,
    m.monto_ultimo_pago,
    m.reestructurado,
    m.castigado,
    m.porcentaje_amortizado,
    m.avance_pagos,
    m.bucket_atraso,
    m.valor_garantia_total,
    m.valor_recuperable_garantia,
    m.cobertura_garantia,
    m.fecha_evaluacion,
    m.score_riesgo,
    m.pd,
    m.lgd,
    m.ead,
    m.perdida_esperada,
    m.clasificacion_riesgo,
    m.semaforo,
    m.dictamen,
    m.perdida_esperada_calculada,
    m.perdida_esperada_sobre_saldo,
    m.etapa_riesgo_siarc,
    m.clasificacion_cartera_siarc,
    m.reserva_estimada_siarc,
    m.fecha_generacion,
    r.porcentaje_reserva,
    (m.saldo_actual * r.porcentaje_reserva) AS reserva_regulatoria,
        CASE
            WHEN (m.etapa_riesgo_siarc = 'ETAPA 1'::text) THEN 'VIGENTE'::text
            WHEN (m.etapa_riesgo_siarc = 'ETAPA 2'::text) THEN 'RIESGO SIGNIFICATIVO'::text
            ELSE 'DETERIORADO'::text
        END AS clasificacion_regulatoria
   FROM (siarc.mv_riesgo_cartera m
     LEFT JOIN siarc.cat_reserva_riesgo r ON ((m.etapa_riesgo_siarc = (r.etapa_riesgo)::text)));


--
-- Name: vw_coberturas_fondo_credito; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_coberturas_fondo_credito AS
 SELECT c.id_cobertura,
    cr.codigo_credito,
    cr.nombre_acreditado,
    f.clave AS fondo,
    f.nombre AS nombre_fondo,
    c.porcentaje_cobertura,
    c.monto_base_cobertura,
    c.monto_maximo_cubierto,
    c.estatus_cobertura,
    c.fecha_alta,
    c.observaciones
   FROM ((siarc.tb_credito_cobertura_garantia c
     JOIN siarc.tb_credito_originado cr ON ((c.id_credito_originado = cr.id_credito_originado)))
     JOIN siarc.cat_fondo_garantia f ON ((c.id_fondo = f.id_fondo)));


--
-- Name: vw_riesgo_creditos_vivos; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_riesgo_creditos_vivos AS
 SELECT id_credito_originado,
    codigo_credito,
    nombre_acreditado,
    producto,
    destino_credito,
    monto_aprobado,
    saldo_actual,
    monto_vencido,
    dias_atraso,
    etapa_riesgo,
    clasificacion_cartera,
        CASE
            WHEN (dias_atraso >= 90) THEN 0.60000000
            WHEN (dias_atraso >= 61) THEN 0.35000000
            WHEN (dias_atraso >= 31) THEN 0.18000000
            WHEN (dias_atraso >= 1) THEN 0.08000000
            ELSE 0.03000000
        END AS pd,
        CASE
            WHEN (saldo_actual <= (0)::numeric) THEN (0)::numeric
            ELSE 0.60000000
        END AS lgd,
    saldo_actual AS ead,
    ((saldo_actual *
        CASE
            WHEN (dias_atraso >= 90) THEN 0.60000000
            WHEN (dias_atraso >= 61) THEN 0.35000000
            WHEN (dias_atraso >= 31) THEN 0.18000000
            WHEN (dias_atraso >= 1) THEN 0.08000000
            ELSE 0.03000000
        END) *
        CASE
            WHEN (saldo_actual <= (0)::numeric) THEN (0)::numeric
            ELSE 0.60000000
        END) AS perdida_esperada,
        CASE
            WHEN (dias_atraso >= 90) THEN 'ROJO'::text
            WHEN (dias_atraso >= 1) THEN 'AMARILLO'::text
            ELSE 'VERDE'::text
        END AS semaforo,
        CASE
            WHEN (dias_atraso >= 90) THEN 'RECUPERACION INTENSIVA'::text
            WHEN (dias_atraso >= 31) THEN 'COBRANZA PREVENTIVA'::text
            WHEN (dias_atraso >= 1) THEN 'VIGILANCIA'::text
            ELSE 'NORMAL'::text
        END AS estatus_gestion_riesgo
   FROM siarc.vw_cartera_crediticia;


--
-- Name: vw_cobranza_creditos; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_cobranza_creditos AS
 SELECT r.id_credito_originado,
    r.codigo_credito,
    r.nombre_acreditado,
    r.saldo_actual,
    r.monto_vencido,
    r.dias_atraso,
    r.pd,
    r.lgd,
    r.ead,
    r.perdida_esperada,
    r.semaforo,
    r.estatus_gestion_riesgo,
    g.fecha_gestion AS ultima_fecha_gestion,
    g.tipo_gestion AS ultimo_tipo_gestion,
    g.resultado_gestion AS ultimo_resultado_gestion,
    g.comentario AS ultimo_comentario,
    g.promesa_pago,
    g.fecha_promesa_pago,
    g.monto_promesa_pago,
    g.usuario AS ultimo_usuario_gestion
   FROM (siarc.vw_riesgo_creditos_vivos r
     LEFT JOIN LATERAL ( SELECT g_1.id_gestion,
            g_1.id_credito_originado,
            g_1.fecha_gestion,
            g_1.tipo_gestion,
            g_1.resultado_gestion,
            g_1.comentario,
            g_1.promesa_pago,
            g_1.fecha_promesa_pago,
            g_1.monto_promesa_pago,
            g_1.usuario,
            g_1.fecha_registro
           FROM siarc.tb_gestion_cobranza g_1
          WHERE (g_1.id_credito_originado = r.id_credito_originado)
          ORDER BY g_1.fecha_gestion DESC
         LIMIT 1) g ON (true));


--
-- Name: vw_cobranza_prioridades; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_cobranza_prioridades AS
 SELECT id_credito_originado,
    codigo_credito,
    nombre_acreditado,
    saldo_actual,
    monto_vencido,
    dias_atraso,
    pd,
    lgd,
    ead,
    perdida_esperada,
    semaforo,
    estatus_gestion_riesgo,
    ultima_fecha_gestion,
    ultimo_tipo_gestion,
    ultimo_resultado_gestion,
    ultimo_comentario,
    promesa_pago,
    fecha_promesa_pago,
    monto_promesa_pago,
    ultimo_usuario_gestion,
        CASE
            WHEN (semaforo = 'ROJO'::text) THEN 1
            WHEN (semaforo = 'AMARILLO'::text) THEN 2
            ELSE 3
        END AS prioridad_cobranza,
        CASE
            WHEN (dias_atraso >= 90) THEN 'URGENTE'::text
            WHEN (dias_atraso >= 31) THEN 'ALTA'::text
            WHEN (dias_atraso >= 1) THEN 'MEDIA'::text
            ELSE 'BAJA'::text
        END AS nivel_prioridad
   FROM siarc.vw_cobranza_creditos
  ORDER BY
        CASE
            WHEN (semaforo = 'ROJO'::text) THEN 1
            WHEN (semaforo = 'AMARILLO'::text) THEN 2
            ELSE 3
        END, dias_atraso DESC, perdida_esperada DESC;


--
-- Name: vw_comite_solicitudes; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_comite_solicitudes AS
 SELECT s.id_solicitud,
    s.folio_solicitud,
    s.fecha_solicitud,
    (((((s.nombre)::text || ' '::text) || (COALESCE(s.paterno, ''::character varying))::text) || ' '::text) || (COALESCE(s.materno, ''::character varying))::text) AS solicitante,
    s.monto_solicitado,
    s.plazo_meses,
    s.estatus,
    a.score_final,
    a.pd_estimada,
    a.lgd_estimada,
    a.perdida_esperada_estimada,
    a.semaforo,
    a.nivel_riesgo,
    a.monto_recomendado,
    a.dictamen,
    c.fecha_comite,
    c.decision,
    c.monto_aprobado,
    c.plazo_aprobado,
    c.tasa_aprobada,
    c.condiciones,
    c.comentarios,
    c.usuario_comite
   FROM ((siarc.tb_solicitud_credito s
     LEFT JOIN LATERAL ( SELECT a_1.id_analisis,
            a_1.id_solicitud,
            a_1.fecha_analisis,
            a_1.ingreso_mensual,
            a_1.egreso_mensual,
            a_1.ingreso_disponible,
            a_1.monto_solicitado,
            a_1.plazo_meses,
            a_1.tasa_interes_anual,
            a_1.pago_estimado_mensual,
            a_1.relacion_pago_ingreso,
            a_1.valor_garantia,
            a_1.cobertura_garantia,
            a_1.score_capacidad_pago,
            a_1.score_garantia,
            a_1.score_plazo,
            a_1.score_final,
            a_1.pd_estimada,
            a_1.lgd_estimada,
            a_1.ead_estimada,
            a_1.perdida_esperada_estimada,
            a_1.semaforo,
            a_1.nivel_riesgo,
            a_1.monto_recomendado,
            a_1.dictamen,
            a_1.analista,
            a_1.observaciones
           FROM siarc.tb_analisis_credito a_1
          WHERE (a_1.id_solicitud = s.id_solicitud)
          ORDER BY a_1.fecha_analisis DESC
         LIMIT 1) a ON (true))
     LEFT JOIN LATERAL ( SELECT c_1.id_comite,
            c_1.id_solicitud,
            c_1.fecha_comite,
            c_1.decision,
            c_1.monto_aprobado,
            c_1.plazo_aprobado,
            c_1.tasa_aprobada,
            c_1.condiciones,
            c_1.comentarios,
            c_1.usuario_comite
           FROM siarc.tb_comite_credito c_1
          WHERE (c_1.id_solicitud = s.id_solicitud)
          ORDER BY c_1.fecha_comite DESC
         LIMIT 1) c ON (true));


--
-- Name: vw_concentracion_cliente; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_concentracion_cliente AS
 SELECT nombre_cliente,
    count(*) AS total_creditos,
    sum(saldo_actual) AS saldo_total,
    sum(perdida_esperada) AS perdida_esperada,
    max(semaforo) AS semaforo
   FROM siarc.mv_riesgo_cartera
  GROUP BY nombre_cliente;


--
-- Name: vw_concentracion_estado; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_concentracion_estado AS
 SELECT COALESCE(estado, 'SIN ESTADO'::text) AS estado,
    count(*) AS total_creditos,
    sum(monto_original) AS monto_original_total,
    sum(saldo_actual) AS saldo_total,
    sum(saldo_vencido) AS saldo_vencido_total,
        CASE
            WHEN (sum(saldo_actual) > (0)::numeric) THEN (sum(saldo_vencido) / sum(saldo_actual))
            ELSE (0)::numeric
        END AS imor,
    avg(pd) AS pd_promedio,
    sum(perdida_esperada_calculada) AS perdida_esperada_total
   FROM siarc.vw_cartera_riesgo
  GROUP BY COALESCE(estado, 'SIN ESTADO'::text);


--
-- Name: vw_concentracion_producto; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_concentracion_producto AS
 SELECT COALESCE(nombre_producto, 'SIN PRODUCTO'::text) AS nombre_producto,
    count(*) AS total_creditos,
    sum(monto_original) AS monto_original_total,
    sum(saldo_actual) AS saldo_total,
    sum(saldo_vencido) AS saldo_vencido_total,
        CASE
            WHEN (sum(saldo_actual) > (0)::numeric) THEN (sum(saldo_vencido) / sum(saldo_actual))
            ELSE (0)::numeric
        END AS imor,
    avg(pd) AS pd_promedio,
    sum(perdida_esperada_calculada) AS perdida_esperada_total
   FROM siarc.vw_cartera_riesgo
  GROUP BY COALESCE(nombre_producto, 'SIN PRODUCTO'::text);


--
-- Name: vw_creditos_originados; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_creditos_originados AS
 SELECT co.id_credito_originado,
    co.codigo_credito,
    co.fecha_formalizacion,
    co.nombre_acreditado,
    co.producto,
    co.destino_credito,
    co.monto_aprobado,
    co.plazo_meses,
    co.tasa_interes_anual,
    co.saldo_actual,
    co.estatus_credito,
    s.folio_solicitud,
    s.estatus AS estatus_solicitud
   FROM (siarc.tb_credito_originado co
     JOIN siarc.tb_solicitud_credito s ON ((co.id_solicitud = s.id_solicitud)));


--
-- Name: vw_dashboard_alertas; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_dashboard_alertas AS
 SELECT codigo_credito,
    nombre_acreditado,
    saldo_actual,
    monto_vencido,
    dias_atraso,
    etapa_riesgo,
    semaforo,
    estatus_gestion_riesgo,
        CASE
            WHEN (dias_atraso >= 180) THEN 'ELEGIBLE FONAGA'::text
            WHEN (dias_atraso >= 90) THEN 'DETERIORADO'::text
            WHEN (dias_atraso >= 31) THEN 'COBRANZA PRIORITARIA'::text
            WHEN (dias_atraso >= 1) THEN 'VIGILANCIA'::text
            ELSE 'NORMAL'::text
        END AS alerta_operativa
   FROM siarc.vw_riesgo_creditos_vivos
  ORDER BY dias_atraso DESC;


--
-- Name: vw_polizas_contables_detalle; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_polizas_contables_detalle AS
 SELECT p.id_poliza,
    p.fecha_poliza,
    p.clave_evento,
    p.referencia,
    p.descripcion AS descripcion_poliza,
    p.origen_modulo,
    p.estatus,
    d.cuenta,
    c.nombre_cuenta,
    c.tipo_cuenta,
    c.naturaleza,
    d.descripcion AS descripcion_movimiento,
    d.cargo,
    d.abono
   FROM ((siarc.tb_poliza_contable p
     JOIN siarc.tb_poliza_detalle d ON ((p.id_poliza = d.id_poliza)))
     JOIN siarc.cat_cuenta_contable c ON (((d.cuenta)::text = (c.cuenta)::text)));


--
-- Name: vw_resumen_contable; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_resumen_contable AS
 SELECT cuenta,
    nombre_cuenta,
    tipo_cuenta,
    naturaleza,
    sum(cargo) AS total_cargos,
    sum(abono) AS total_abonos,
        CASE
            WHEN ((naturaleza)::text = 'DEUDORA'::text) THEN (sum(cargo) - sum(abono))
            ELSE (sum(abono) - sum(cargo))
        END AS saldo_contable
   FROM siarc.vw_polizas_contables_detalle
  GROUP BY cuenta, nombre_cuenta, tipo_cuenta, naturaleza;


--
-- Name: vw_dashboard_contable; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_dashboard_contable AS
 SELECT tipo_cuenta,
    cuenta,
    nombre_cuenta,
    naturaleza,
    total_cargos,
    total_abonos,
    saldo_contable
   FROM siarc.vw_resumen_contable
  ORDER BY cuenta;


--
-- Name: vw_garantias_agro_credito; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_garantias_agro_credito AS
 SELECT c.id_credito_originado,
    c.codigo_credito,
    c.nombre_acreditado,
    c.producto,
    c.monto_aprobado,
    c.saldo_actual,
    m.clave AS clave_mitigante,
    m.nombre AS nombre_mitigante,
    m.tipo AS tipo_mitigante,
    m.factor_reduccion_lgd,
    cm.porcentaje_cobertura,
    cm.monto_cubierto,
    cm.observaciones,
    cm.activo,
    cm.fecha_registro
   FROM ((siarc.tb_credito_mitigante_riesgo cm
     JOIN siarc.tb_credito_originado c ON ((cm.id_credito_originado = c.id_credito_originado)))
     JOIN siarc.cat_mitigante_riesgo_agro m ON ((cm.id_mitigante = m.id_mitigante)))
  WHERE (cm.activo = true);


--
-- Name: vw_lgd_ajustada_credito; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_lgd_ajustada_credito AS
 WITH mitigantes AS (
         SELECT g.id_credito_originado,
            sum(COALESCE(g.porcentaje_cobertura, (0)::numeric)) AS cobertura_total,
            sum((COALESCE(g.porcentaje_cobertura, (0)::numeric) * COALESCE(g.factor_reduccion_lgd, (0)::numeric))) AS reduccion_ponderada_lgd
           FROM siarc.vw_garantias_agro_credito g
          GROUP BY g.id_credito_originado
        )
 SELECT r.id_credito_originado,
    r.codigo_credito,
    r.nombre_acreditado,
    r.pd,
    r.lgd AS lgd_base,
    r.ead,
    COALESCE(m.cobertura_total, (0)::numeric) AS cobertura_total,
    COALESCE(m.reduccion_ponderada_lgd, (0)::numeric) AS reduccion_lgd,
    GREATEST((r.lgd - COALESCE(m.reduccion_ponderada_lgd, (0)::numeric)), 0.0500) AS lgd_ajustada,
    r.semaforo,
    r.dias_atraso,
    r.etapa_riesgo
   FROM (siarc.vw_riesgo_creditos_vivos r
     LEFT JOIN mitigantes m ON ((r.id_credito_originado = m.id_credito_originado)));


--
-- Name: vw_perdida_esperada_ajustada; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_perdida_esperada_ajustada AS
 SELECT id_credito_originado,
    codigo_credito,
    nombre_acreditado,
    dias_atraso,
    etapa_riesgo,
    semaforo,
    pd,
    lgd_base,
    lgd_ajustada,
    ead,
    ((pd * lgd_base) * ead) AS perdida_esperada_base,
    ((pd * lgd_ajustada) * ead) AS perdida_esperada_ajustada,
    (((pd * lgd_base) * ead) - ((pd * lgd_ajustada) * ead)) AS reduccion_perdida_esperada
   FROM siarc.vw_lgd_ajustada_credito l;


--
-- Name: vw_polizas_balance; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_polizas_balance AS
 SELECT id_poliza,
    clave_evento,
    referencia,
    fecha_poliza,
    sum(cargo) AS total_cargos,
    sum(abono) AS total_abonos,
    (sum(cargo) - sum(abono)) AS diferencia,
        CASE
            WHEN (round((sum(cargo) - sum(abono)), 2) = (0)::numeric) THEN 'CUADRADA'::text
            ELSE 'DESCADRADA'::text
        END AS estatus_balance
   FROM siarc.vw_polizas_contables_detalle
  GROUP BY id_poliza, clave_evento, referencia, fecha_poliza;


--
-- Name: vw_reclamaciones_garantia; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_reclamaciones_garantia AS
 WITH pagos AS (
         SELECT tb_pago_garantia_fondo.id_reclamacion,
            sum(tb_pago_garantia_fondo.monto_pagado_fondo) AS total_pagado_fondo
           FROM siarc.tb_pago_garantia_fondo
          GROUP BY tb_pago_garantia_fondo.id_reclamacion
        ), recuperaciones AS (
         SELECT tb_recuperacion_post_garantia.id_reclamacion,
            sum(tb_recuperacion_post_garantia.monto_recuperado) AS total_recuperado,
            sum(tb_recuperacion_post_garantia.monto_para_fondo) AS recuperado_para_fondo,
            sum(tb_recuperacion_post_garantia.monto_para_institucion) AS recuperado_para_institucion
           FROM siarc.tb_recuperacion_post_garantia
          GROUP BY tb_recuperacion_post_garantia.id_reclamacion
        )
 SELECT r.id_reclamacion,
    cr.codigo_credito,
    cr.nombre_acreditado,
    f.clave AS fondo,
    r.fecha_reclamacion,
    r.saldo_reclamado,
    r.porcentaje_cobertura,
    r.monto_reclamado_fondo,
    r.monto_a_cargo_institucion,
    r.estatus_reclamacion,
    COALESCE(p.total_pagado_fondo, (0)::numeric) AS total_pagado_fondo,
    COALESCE(rec.total_recuperado, (0)::numeric) AS total_recuperado,
    COALESCE(rec.recuperado_para_fondo, (0)::numeric) AS recuperado_para_fondo,
    COALESCE(rec.recuperado_para_institucion, (0)::numeric) AS recuperado_para_institucion
   FROM (((((siarc.tb_reclamacion_garantia r
     JOIN siarc.tb_credito_cobertura_garantia c ON ((r.id_cobertura = c.id_cobertura)))
     JOIN siarc.tb_credito_originado cr ON ((c.id_credito_originado = cr.id_credito_originado)))
     JOIN siarc.cat_fondo_garantia f ON ((c.id_fondo = f.id_fondo)))
     LEFT JOIN pagos p ON ((r.id_reclamacion = p.id_reclamacion)))
     LEFT JOIN recuperaciones rec ON ((r.id_reclamacion = rec.id_reclamacion)));


--
-- Name: vw_reserva_credito_ifrs9; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_reserva_credito_ifrs9 AS
 SELECT r.id_credito_originado,
    r.codigo_credito,
    r.nombre_acreditado,
    r.dias_atraso,
    r.etapa_riesgo,
    r.semaforo,
    r.pd,
    r.lgd_base,
    r.lgd_ajustada,
    r.ead,
    r.perdida_esperada_base,
    r.perdida_esperada_ajustada,
    p.factor_reserva,
    (r.perdida_esperada_base * p.factor_reserva) AS reserva_bruta,
    (r.perdida_esperada_ajustada * p.factor_reserva) AS reserva_ajustada_mitigantes,
    ((r.perdida_esperada_base - r.perdida_esperada_ajustada) * p.factor_reserva) AS reduccion_reserva_mitigantes
   FROM (siarc.vw_perdida_esperada_ajustada r
     JOIN siarc.cat_parametro_reserva_ifrs9 p ON ((r.etapa_riesgo = (p.etapa_riesgo)::text)))
  WHERE (p.activo = true);


--
-- Name: vw_reserva_credito_fonaga; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_reserva_credito_fonaga AS
 SELECT res.id_credito_originado,
    res.codigo_credito,
    res.nombre_acreditado,
    res.dias_atraso,
    res.etapa_riesgo,
    res.semaforo,
    res.pd,
    res.lgd_base,
    res.lgd_ajustada,
    res.ead,
    res.reserva_bruta,
    res.reserva_ajustada_mitigantes,
    COALESCE(max(c.porcentaje_cobertura), (0)::numeric) AS porcentaje_cobertura_fondo,
    (res.reserva_ajustada_mitigantes * COALESCE(max(c.porcentaje_cobertura), (0)::numeric)) AS reserva_cubierta_fondo,
    (res.reserva_ajustada_mitigantes * ((1)::numeric - COALESCE(max(c.porcentaje_cobertura), (0)::numeric))) AS reserva_neta_institucion,
    (res.reserva_bruta - (res.reserva_ajustada_mitigantes * ((1)::numeric - COALESCE(max(c.porcentaje_cobertura), (0)::numeric)))) AS reduccion_total_reserva
   FROM (siarc.vw_reserva_credito_ifrs9 res
     LEFT JOIN siarc.tb_credito_cobertura_garantia c ON (((res.id_credito_originado = c.id_credito_originado) AND ((c.estatus_cobertura)::text = ANY ((ARRAY['ACTIVA'::character varying, 'RECLAMADA'::character varying])::text[])))))
  GROUP BY res.id_credito_originado, res.codigo_credito, res.nombre_acreditado, res.dias_atraso, res.etapa_riesgo, res.semaforo, res.pd, res.lgd_base, res.lgd_ajustada, res.ead, res.reserva_bruta, res.reserva_ajustada_mitigantes;


--
-- Name: vw_reserva_portafolio_ifrs9; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_reserva_portafolio_ifrs9 AS
 SELECT count(*) AS total_creditos,
    sum(ead) AS saldo_total_expuesto,
    avg(pd) AS pd_promedio,
    avg(lgd_base) AS lgd_base_promedio,
    avg(lgd_ajustada) AS lgd_ajustada_promedio,
    sum(reserva_bruta) AS reserva_bruta_total,
    sum(reserva_ajustada_mitigantes) AS reserva_ajustada_mitigantes_total,
    sum(reserva_cubierta_fondo) AS reserva_cubierta_fondo_total,
    sum(reserva_neta_institucion) AS reserva_neta_institucion_total,
    sum(reduccion_total_reserva) AS reduccion_total_reserva,
    sum(
        CASE
            WHEN (etapa_riesgo = 'ETAPA 1'::text) THEN 1
            ELSE 0
        END) AS creditos_etapa_1,
    sum(
        CASE
            WHEN (etapa_riesgo = 'ETAPA 2'::text) THEN 1
            ELSE 0
        END) AS creditos_etapa_2,
    sum(
        CASE
            WHEN (etapa_riesgo = 'ETAPA 3'::text) THEN 1
            ELSE 0
        END) AS creditos_etapa_3
   FROM siarc.vw_reserva_credito_fonaga;


--
-- Name: vw_resumen_cartera_originada; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_resumen_cartera_originada AS
 SELECT count(*) AS total_creditos,
    sum(monto_aprobado) AS monto_original_total,
    sum(saldo_actual) AS saldo_total,
    sum(monto_vencido) AS saldo_vencido,
        CASE
            WHEN (sum(saldo_actual) > (0)::numeric) THEN (sum(monto_vencido) / sum(saldo_actual))
            ELSE (0)::numeric
        END AS imor,
    avg(pd) AS pd_promedio,
    avg(lgd) AS lgd_promedio,
    sum(ead) AS ead_total,
    sum(perdida_esperada) AS perdida_esperada_total,
    sum(
        CASE
            WHEN (semaforo = 'VERDE'::text) THEN 1
            ELSE 0
        END) AS creditos_verdes,
    sum(
        CASE
            WHEN (semaforo = 'AMARILLO'::text) THEN 1
            ELSE 0
        END) AS creditos_amarillos,
    sum(
        CASE
            WHEN (semaforo = 'ROJO'::text) THEN 1
            ELSE 0
        END) AS creditos_rojos,
    sum(
        CASE
            WHEN (etapa_riesgo = 'ETAPA 1'::text) THEN 1
            ELSE 0
        END) AS etapa_1,
    sum(
        CASE
            WHEN (etapa_riesgo = 'ETAPA 2'::text) THEN 1
            ELSE 0
        END) AS etapa_2,
    sum(
        CASE
            WHEN (etapa_riesgo = 'ETAPA 3'::text) THEN 1
            ELSE 0
        END) AS etapa_3
   FROM siarc.vw_riesgo_creditos_vivos;


--
-- Name: vw_dashboard_ejecutivo; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_dashboard_ejecutivo AS
 SELECT CURRENT_DATE AS fecha_corte,
    c.total_creditos,
    c.monto_original_total,
    c.saldo_total,
    c.saldo_vencido,
    c.imor,
    c.pd_promedio,
    c.lgd_promedio,
    c.ead_total,
    c.perdida_esperada_total,
    c.creditos_verdes,
    c.creditos_amarillos,
    c.creditos_rojos,
    c.etapa_1,
    c.etapa_2,
    c.etapa_3,
    r.reserva_bruta_total,
    r.reserva_ajustada_mitigantes_total,
    r.reserva_cubierta_fondo_total,
    r.reserva_neta_institucion_total,
    r.reduccion_total_reserva,
    f.reclamaciones AS reclamaciones_fonaga,
    f.saldo_reclamado_total,
    f.monto_reclamado_fondo_total,
    f.total_pagado_fondo,
    f.total_recuperado,
    f.recuperado_para_fondo,
    f.recuperado_para_institucion,
    p.total_polizas,
    p.polizas_cuadradas,
    p.polizas_descuadradas
   FROM (((siarc.vw_resumen_cartera_originada c
     LEFT JOIN siarc.vw_reserva_portafolio_ifrs9 r ON (true))
     LEFT JOIN ( SELECT count(*) AS reclamaciones,
            COALESCE(sum(vw_reclamaciones_garantia.saldo_reclamado), (0)::numeric) AS saldo_reclamado_total,
            COALESCE(sum(vw_reclamaciones_garantia.monto_reclamado_fondo), (0)::numeric) AS monto_reclamado_fondo_total,
            COALESCE(sum(vw_reclamaciones_garantia.total_pagado_fondo), (0)::numeric) AS total_pagado_fondo,
            COALESCE(sum(vw_reclamaciones_garantia.total_recuperado), (0)::numeric) AS total_recuperado,
            COALESCE(sum(vw_reclamaciones_garantia.recuperado_para_fondo), (0)::numeric) AS recuperado_para_fondo,
            COALESCE(sum(vw_reclamaciones_garantia.recuperado_para_institucion), (0)::numeric) AS recuperado_para_institucion
           FROM siarc.vw_reclamaciones_garantia) f ON (true))
     LEFT JOIN ( SELECT count(*) AS total_polizas,
            sum(
                CASE
                    WHEN (vw_polizas_balance.estatus_balance = 'CUADRADA'::text) THEN 1
                    ELSE 0
                END) AS polizas_cuadradas,
            sum(
                CASE
                    WHEN (vw_polizas_balance.estatus_balance = 'DESCADRADA'::text) THEN 1
                    ELSE 0
                END) AS polizas_descuadradas
           FROM siarc.vw_polizas_balance) p ON (true));


--
-- Name: vw_dashboard_fonaga; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_dashboard_fonaga AS
 SELECT fondo,
    reclamaciones,
    saldo_reclamado_total,
    monto_reclamado_fondo_total,
    monto_a_cargo_institucion_total,
    total_pagado_fondo,
    total_recuperado,
    recuperado_para_fondo,
    recuperado_para_institucion,
    round(
        CASE
            WHEN (total_pagado_fondo > (0)::numeric) THEN ((recuperado_para_fondo / total_pagado_fondo) * (100)::numeric)
            ELSE (0)::numeric
        END, 2) AS porcentaje_recuperacion_fondo,
    round(
        CASE
            WHEN (saldo_reclamado_total > (0)::numeric) THEN ((monto_reclamado_fondo_total / saldo_reclamado_total) * (100)::numeric)
            ELSE (0)::numeric
        END, 2) AS cobertura_promedio,
    (total_pagado_fondo - recuperado_para_fondo) AS perdida_neta_fondo,
    (monto_a_cargo_institucion_total - recuperado_para_institucion) AS perdida_neta_institucion
   FROM ( SELECT vw_reclamaciones_garantia.fondo,
            count(*) AS reclamaciones,
            COALESCE(sum(vw_reclamaciones_garantia.saldo_reclamado), (0)::numeric) AS saldo_reclamado_total,
            COALESCE(sum(vw_reclamaciones_garantia.monto_reclamado_fondo), (0)::numeric) AS monto_reclamado_fondo_total,
            COALESCE(sum(vw_reclamaciones_garantia.monto_a_cargo_institucion), (0)::numeric) AS monto_a_cargo_institucion_total,
            COALESCE(sum(vw_reclamaciones_garantia.total_pagado_fondo), (0)::numeric) AS total_pagado_fondo,
            COALESCE(sum(vw_reclamaciones_garantia.total_recuperado), (0)::numeric) AS total_recuperado,
            COALESCE(sum(vw_reclamaciones_garantia.recuperado_para_fondo), (0)::numeric) AS recuperado_para_fondo,
            COALESCE(sum(vw_reclamaciones_garantia.recuperado_para_institucion), (0)::numeric) AS recuperado_para_institucion
           FROM siarc.vw_reclamaciones_garantia
          GROUP BY vw_reclamaciones_garantia.fondo) x;


--
-- Name: vw_dashboard_riesgo; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_dashboard_riesgo AS
 SELECT etapa_riesgo,
    semaforo,
    count(*) AS creditos,
    sum(saldo_actual) AS saldo_total,
    sum(monto_vencido) AS monto_vencido,
    avg(pd) AS pd_promedio,
    avg(lgd) AS lgd_promedio,
    sum(ead) AS ead_total,
    sum(perdida_esperada) AS perdida_esperada_total
   FROM siarc.vw_riesgo_creditos_vivos
  GROUP BY etapa_riesgo, semaforo
  ORDER BY etapa_riesgo, semaforo;


--
-- Name: vw_estado_markov_actual; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_estado_markov_actual AS
 SELECT id_credito,
        CASE
            WHEN (dias_atraso = 0) THEN 'V'::text
            WHEN ((dias_atraso >= 1) AND (dias_atraso <= 30)) THEN 'M1'::text
            WHEN ((dias_atraso >= 31) AND (dias_atraso <= 60)) THEN 'M2'::text
            WHEN ((dias_atraso >= 61) AND (dias_atraso <= 90)) THEN 'M3'::text
            WHEN (dias_atraso > 90) THEN 'M4'::text
            ELSE 'V'::text
        END AS estado_markov,
    saldo_actual
   FROM siarc.mv_riesgo_cartera;


--
-- Name: vw_riesgo_con_ia; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_riesgo_con_ia AS
 SELECT m.id_credito,
    m.codigo_credito_externo,
    m.id_cliente,
    m.codigo_cliente_externo,
    m.nombre_cliente,
    m.rfc,
    m.curp,
    m.tipo_persona,
    m.actividad_economica,
    m.estado,
    m.municipio,
    m.nombre_producto,
    m.nombre_sucursal,
    m.estado_credito,
    m.frecuencia_pago,
    m.fecha_otorgamiento,
    m.fecha_vencimiento,
    m.plazo_meses,
    m.monto_original,
    m.saldo_actual,
    m.saldo_capital,
    m.saldo_interes,
    m.saldo_moratorio,
    m.tasa_interes_anual,
    m.dias_atraso,
    m.numero_pagos_pactados,
    m.numero_pagos_realizados,
    m.fecha_ultimo_pago,
    m.monto_ultimo_pago,
    m.reestructurado,
    m.castigado,
    m.porcentaje_amortizado,
    m.avance_pagos,
    m.bucket_atraso,
    m.valor_garantia_total,
    m.valor_recuperable_garantia,
    m.cobertura_garantia,
    m.fecha_evaluacion,
    m.score_riesgo,
    m.pd,
    m.lgd,
    m.ead,
    m.perdida_esperada,
    m.clasificacion_riesgo,
    m.semaforo,
    m.dictamen,
    m.perdida_esperada_calculada,
    m.perdida_esperada_sobre_saldo,
    m.etapa_riesgo_siarc,
    m.clasificacion_cartera_siarc,
    m.reserva_estimada_siarc,
    m.fecha_generacion,
    ia.pd_reglas,
    ia.pd_ia,
    ia.pd_final,
    ((m.ead * ia.pd_final) * m.lgd) AS perdida_esperada_ia,
        CASE
            WHEN (m.castigado = true) THEN 'ROJO'::text
            WHEN (ia.pd_final >= 0.60) THEN 'ROJO'::text
            WHEN (ia.pd_final >= 0.10) THEN 'AMARILLO'::text
            ELSE 'VERDE'::text
        END AS semaforo_ia,
        CASE
            WHEN (m.castigado = true) THEN 'CASTIGADO'::text
            WHEN (ia.pd_final >= 0.60) THEN 'RECUPERACION INTENSIVA'::text
            WHEN (ia.pd_final >= 0.30) THEN 'COBRANZA PREVENTIVA'::text
            WHEN (ia.pd_final >= 0.15) THEN 'SEGUIMIENTO ESPECIAL'::text
            WHEN (ia.pd_final >= 0.05) THEN 'VIGILANCIA'::text
            ELSE 'NORMAL'::text
        END AS estatus_gestion_riesgo,
        CASE
            WHEN (m.castigado = true) THEN 'Credito castigado; mantener control de recuperacion.'::text
            WHEN (ia.pd_final >= 0.60) THEN 'Alta probabilidad de incumplimiento; enviar a recuperacion intensiva.'::text
            WHEN (ia.pd_final >= 0.30) THEN 'Riesgo alto; activar cobranza preventiva y revisar plan de pagos.'::text
            WHEN (ia.pd_final >= 0.15) THEN 'Riesgo medio; seguimiento especial por parte del area de riesgos.'::text
            WHEN (ia.pd_final >= 0.05) THEN 'Riesgo bajo-medio; mantener vigilancia periodica.'::text
            ELSE 'Cartera normal; continuar monitoreo ordinario.'::text
        END AS recomendacion_gestion
   FROM (siarc.mv_riesgo_cartera m
     LEFT JOIN ( SELECT DISTINCT ON (tb_resultado_ia_pd.id_credito) tb_resultado_ia_pd.id_credito,
            tb_resultado_ia_pd.pd_reglas,
            tb_resultado_ia_pd.pd_ia,
            tb_resultado_ia_pd.pd_final,
            tb_resultado_ia_pd.fecha_calculo
           FROM siarc.tb_resultado_ia_pd
          ORDER BY tb_resultado_ia_pd.id_credito, tb_resultado_ia_pd.fecha_calculo DESC) ia ON ((m.id_credito = ia.id_credito)));


--
-- Name: vw_estado_markov_ia_actual; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_estado_markov_ia_actual AS
 SELECT id_credito,
    saldo_actual,
    pd_final,
        CASE
            WHEN (dias_atraso = 0) THEN 'V'::text
            WHEN ((dias_atraso >= 1) AND (dias_atraso <= 30)) THEN 'M1'::text
            WHEN ((dias_atraso >= 31) AND (dias_atraso <= 60)) THEN 'M2'::text
            WHEN ((dias_atraso >= 61) AND (dias_atraso <= 90)) THEN 'M3'::text
            WHEN (dias_atraso > 90) THEN 'M4'::text
            ELSE 'V'::text
        END AS estado_markov,
        CASE
            WHEN (pd_final >= 0.60) THEN 1.40
            WHEN (pd_final >= 0.30) THEN 1.25
            WHEN (pd_final >= 0.15) THEN 1.10
            WHEN (pd_final >= 0.05) THEN 1.05
            ELSE 1.00
        END AS factor_deterioro_ia
   FROM siarc.vw_riesgo_con_ia;


--
-- Name: vw_log_acceso; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_log_acceso AS
 SELECT id_log,
    fecha_evento,
    usuario,
    rol,
    ip_origen,
    evento,
    descripcion
   FROM siarc.tb_log_acceso
  ORDER BY fecha_evento DESC;


--
-- Name: vw_markov_distribucion_actual; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_markov_distribucion_actual AS
 SELECT estado_markov,
    count(*) AS total_creditos,
    sum(saldo_actual) AS saldo_total
   FROM siarc.vw_estado_markov_actual
  GROUP BY estado_markov;


--
-- Name: vw_markov_transiciones; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_markov_transiciones AS
 SELECT a.id_credito,
    a.estado_markov AS estado_origen,
    b.estado_markov AS estado_destino,
    a.fecha_corte AS fecha_origen,
    b.fecha_corte AS fecha_destino
   FROM (siarc.tb_markov_historico a
     JOIN siarc.tb_markov_historico b ON (((a.id_credito = b.id_credito) AND (b.fecha_corte > a.fecha_corte))));


--
-- Name: vw_markov_matriz_real; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_markov_matriz_real AS
 SELECT estado_origen,
    estado_destino,
    count(*) AS total_movimientos,
    ((count(*))::numeric / sum(count(*)) OVER (PARTITION BY estado_origen)) AS probabilidad
   FROM siarc.vw_markov_transiciones
  GROUP BY estado_origen, estado_destino;


--
-- Name: vw_matriz_markov_ia; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_matriz_markov_ia AS
 WITH factores AS (
         SELECT vw_estado_markov_ia_actual.id_credito,
            vw_estado_markov_ia_actual.factor_deterioro_ia
           FROM siarc.vw_estado_markov_ia_actual
        ), base AS (
         SELECT f.id_credito,
            (m.estado_origen)::text AS estado_origen,
            (m.estado_destino)::text AS estado_destino,
            m.probabilidad,
            f.factor_deterioro_ia,
                CASE
                    WHEN ((m.estado_destino)::text = ANY ((ARRAY['M1'::character varying, 'M2'::character varying, 'M3'::character varying, 'M4'::character varying, 'P'::character varying])::text[])) THEN (m.probabilidad * f.factor_deterioro_ia)
                    ELSE m.probabilidad
                END AS probabilidad_ajustada_previa
           FROM (factores f
             CROSS JOIN siarc.tb_matriz_markov_base m)
        ), normalizada AS (
         SELECT base.id_credito,
            base.estado_origen,
            base.estado_destino,
            (base.probabilidad_ajustada_previa / sum(base.probabilidad_ajustada_previa) OVER (PARTITION BY base.id_credito, base.estado_origen)) AS probabilidad_ajustada
           FROM base
        )
 SELECT id_credito,
    estado_origen,
    estado_destino,
    probabilidad_ajustada
   FROM normalizada;


--
-- Name: vw_montecarlo_ia_ultima_simulacion; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_montecarlo_ia_ultima_simulacion AS
 SELECT id_simulacion,
    fecha_simulacion,
    numero_escenarios,
    perdida_promedio,
    perdida_minima,
    perdida_maxima,
    var_95,
    var_99,
    perdida_esperada_ia_base,
    perdida_inesperada_95,
    perdida_inesperada_99
   FROM siarc.tb_montecarlo_ia_cartera
  ORDER BY fecha_simulacion DESC
 LIMIT 1;


--
-- Name: vw_montecarlo_ultima_simulacion; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_montecarlo_ultima_simulacion AS
 SELECT id_simulacion,
    fecha_simulacion,
    numero_escenarios,
    perdida_promedio,
    perdida_minima,
    perdida_maxima,
    var_95,
    var_99,
    perdida_esperada_base,
    perdida_inesperada_95,
    perdida_inesperada_99
   FROM siarc.tb_montecarlo_cartera
  ORDER BY fecha_simulacion DESC
 LIMIT 1;


--
-- Name: vw_pagos_credito; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_pagos_credito AS
 SELECT c.codigo_credito,
    c.nombre_acreditado,
    p.numero_pago,
    p.fecha_pago,
    p.importe_pagado,
    p.capital_pagado,
    p.interes_pagado,
    p.saldo_anterior,
    p.saldo_posterior,
    p.usuario
   FROM (siarc.tb_credito_pago p
     JOIN siarc.tb_credito_originado c ON ((p.id_credito_originado = c.id_credito_originado)))
  ORDER BY p.fecha_pago DESC;


--
-- Name: vw_proyeccion_markov; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_proyeccion_markov AS
 SELECT fecha_proyeccion,
    horizonte_meses,
    estado_markov,
    creditos_esperados,
    saldo_esperado,
        CASE
            WHEN ((estado_markov)::text = 'V'::text) THEN 'VIGENTE'::text
            WHEN ((estado_markov)::text = 'M1'::text) THEN 'MORA 1-30'::text
            WHEN ((estado_markov)::text = 'M2'::text) THEN 'MORA 31-60'::text
            WHEN ((estado_markov)::text = 'M3'::text) THEN 'MORA 61-90'::text
            WHEN ((estado_markov)::text = 'M4'::text) THEN 'MORA 90+'::text
            WHEN ((estado_markov)::text = 'P'::text) THEN 'PERDIDA'::text
            ELSE 'SIN CLASIFICAR'::text
        END AS descripcion_estado
   FROM siarc.tb_proyeccion_markov;


--
-- Name: vw_reporte_cartera_general; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_reporte_cartera_general AS
 SELECT c.id_credito_originado,
    c.codigo_credito,
    c.fecha_formalizacion,
    s.folio_solicitud,
    s.nombre,
    s.paterno,
    s.materno,
    c.nombre_acreditado,
    s.curp,
    s.rfc,
    s.telefono,
    s.correo,
    s.estado,
    s.municipio,
    s.localidad,
    s.domicilio,
    s.actividad_economica,
    s.ingresos_mensuales,
    s.egresos_mensuales,
    c.producto,
    c.destino_credito,
    c.monto_aprobado,
    c.plazo_meses,
    c.tasa_interes_anual,
    c.saldo_inicial,
    c.saldo_actual,
    c.estatus_credito,
    c.fecha_primer_vencimiento,
    c.tipo_amortizacion,
    r.dias_atraso,
    r.etapa_riesgo,
    r.semaforo,
    r.pd,
    r.lgd,
    r.perdida_esperada,
    g.porcentaje_cobertura,
    g.monto_maximo_cubierto,
    g.estatus_cobertura,
    f.clave AS fondo_garantia
   FROM ((((siarc.tb_credito_originado c
     LEFT JOIN siarc.tb_solicitud_credito s ON ((c.id_solicitud = s.id_solicitud)))
     LEFT JOIN siarc.vw_riesgo_creditos_vivos r ON (((c.codigo_credito)::text = (r.codigo_credito)::text)))
     LEFT JOIN siarc.tb_credito_cobertura_garantia g ON ((c.id_credito_originado = g.id_credito_originado)))
     LEFT JOIN siarc.cat_fondo_garantia f ON ((g.id_fondo = f.id_fondo)));


--
-- Name: vw_reporte_reservas_fira; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_reporte_reservas_fira AS
 SELECT codigo_credito_externo AS numero_de_credito,
    CURRENT_DATE AS fecha_de_corte,
    saldo_actual AS saldo_insoluto_a_la_fecha_de_corte,
        CASE
            WHEN (dias_atraso >= 90) THEN 'ETAPA 3'::text
            WHEN ((dias_atraso >= 30) AND (dias_atraso <= 89)) THEN 'ETAPA 2'::text
            ELSE 'ETAPA 1'::text
        END AS etapa_de_riesgo,
    dias_atraso AS dias_atraso_a_la_fecha_de_corte,
    pd_final AS probabilidad_de_incumplimiento_a_la_fecha_de_corte,
    lgd AS severidad_de_la_perdida_a_la_fecha_de_corte,
        CASE
            WHEN (pd_final < 0.05) THEN 'A'::text
            WHEN (pd_final < 0.10) THEN 'B'::text
            WHEN (pd_final < 0.20) THEN 'C'::text
            WHEN (pd_final < 0.40) THEN 'D'::text
            ELSE 'E'::text
        END AS clasificacion_de_riesgo_de_acuerdo_con_el_porcentaje_de_reserva,
        CASE
            WHEN ((dias_atraso >= 30) AND (dias_atraso <= 89)) THEN perdida_esperada_ia
            ELSE (0)::numeric
        END AS reserva_para_creditos_en_etapa_2,
    perdida_esperada_ia AS reserva_total_a_la_fecha_de_corte
   FROM siarc.vw_riesgo_con_ia;


--
-- Name: vw_reporte_reservas_ifrs9; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_reporte_reservas_ifrs9 AS
 SELECT codigo_credito,
    nombre_acreditado,
    CURRENT_DATE AS fecha_corte,
    dias_atraso,
    etapa_riesgo,
    semaforo,
    ead AS saldo_insoluto,
    pd AS probabilidad_incumplimiento,
    lgd_base AS severidad_perdida_base,
    lgd_ajustada AS severidad_perdida_ajustada,
    reserva_bruta,
    reserva_ajustada_mitigantes,
    porcentaje_cobertura_fondo,
    reserva_cubierta_fondo,
    reserva_neta_institucion,
    reduccion_total_reserva
   FROM siarc.vw_reserva_credito_fonaga;


--
-- Name: vw_reserva_por_etapa_ifrs9; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_reserva_por_etapa_ifrs9 AS
 SELECT etapa_riesgo,
    count(*) AS total_creditos,
    sum(ead) AS saldo_expuesto,
    sum(reserva_bruta) AS reserva_bruta,
    sum(reserva_ajustada_mitigantes) AS reserva_ajustada_mitigantes,
    sum(reserva_cubierta_fondo) AS reserva_cubierta_fondo,
    sum(reserva_neta_institucion) AS reserva_neta_institucion,
    sum(reduccion_total_reserva) AS reduccion_total_reserva
   FROM siarc.vw_reserva_credito_fonaga
  GROUP BY etapa_riesgo;


--
-- Name: vw_resumen_auditoria; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_resumen_auditoria AS
 SELECT modulo,
    accion,
    count(*) AS eventos,
    min(fecha_evento) AS primer_evento,
    max(fecha_evento) AS ultimo_evento
   FROM siarc.tb_bitacora_auditoria
  GROUP BY modulo, accion
  ORDER BY modulo, accion;


--
-- Name: vw_resumen_ejecutivo; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_resumen_ejecutivo AS
 SELECT count(*) AS total_creditos,
    count(*) FILTER (WHERE (saldo_actual > (0)::numeric)) AS creditos_con_saldo,
    count(*) FILTER (WHERE (dias_atraso > 0)) AS creditos_con_atraso,
    count(*) FILTER (WHERE (dias_atraso = 0)) AS creditos_sin_atraso,
    sum(monto_original) AS monto_original_total,
    sum(saldo_actual) AS saldo_total,
    sum(saldo_vigente) AS saldo_vigente_total,
    sum(saldo_vencido) AS saldo_vencido_total,
        CASE
            WHEN (sum(saldo_actual) > (0)::numeric) THEN (sum(saldo_vencido) / sum(saldo_actual))
            ELSE (0)::numeric
        END AS imor,
    avg(pd) AS pd_promedio,
    avg(lgd) AS lgd_promedio,
    sum(ead) AS ead_total,
    sum(perdida_esperada_calculada) AS perdida_esperada_total,
        CASE
            WHEN (sum(saldo_actual) > (0)::numeric) THEN (sum(perdida_esperada_calculada) / sum(saldo_actual))
            ELSE (0)::numeric
        END AS perdida_esperada_sobre_cartera
   FROM siarc.vw_cartera_riesgo;


--
-- Name: vw_resumen_fondos_garantia; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_resumen_fondos_garantia AS
 SELECT fondo,
    count(*) AS reclamaciones,
    sum(saldo_reclamado) AS saldo_reclamado_total,
    sum(monto_reclamado_fondo) AS monto_reclamado_fondo_total,
    sum(monto_a_cargo_institucion) AS monto_a_cargo_institucion_total,
    sum(total_pagado_fondo) AS total_pagado_fondo,
    sum(total_recuperado) AS total_recuperado,
    sum(recuperado_para_fondo) AS recuperado_para_fondo,
    sum(recuperado_para_institucion) AS recuperado_para_institucion
   FROM siarc.vw_reclamaciones_garantia
  GROUP BY fondo;


--
-- Name: vw_resumen_garantias_agro; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_resumen_garantias_agro AS
 SELECT count(DISTINCT id_credito_originado) AS creditos_con_mitigante,
    count(*) AS total_mitigantes_asignados,
    sum(COALESCE(monto_cubierto, (0)::numeric)) AS monto_total_cubierto,
    avg(porcentaje_cobertura) AS cobertura_promedio
   FROM siarc.vw_garantias_agro_credito;


--
-- Name: vw_resumen_markov; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_resumen_markov AS
 SELECT horizonte_meses,
    sum(creditos_esperados) AS creditos_totales_esperados,
    sum(saldo_esperado) AS saldo_total_esperado,
    sum(
        CASE
            WHEN ((estado_markov)::text = 'V'::text) THEN saldo_esperado
            ELSE (0)::numeric
        END) AS saldo_vigente_esperado,
    sum(
        CASE
            WHEN ((estado_markov)::text = ANY ((ARRAY['M1'::character varying, 'M2'::character varying, 'M3'::character varying, 'M4'::character varying])::text[])) THEN saldo_esperado
            ELSE (0)::numeric
        END) AS saldo_mora_esperado,
    sum(
        CASE
            WHEN ((estado_markov)::text = 'P'::text) THEN saldo_esperado
            ELSE (0)::numeric
        END) AS saldo_perdida_esperado,
        CASE
            WHEN (sum(saldo_esperado) > (0)::numeric) THEN (sum(
            CASE
                WHEN ((estado_markov)::text = ANY ((ARRAY['M1'::character varying, 'M2'::character varying, 'M3'::character varying, 'M4'::character varying])::text[])) THEN saldo_esperado
                ELSE (0)::numeric
            END) / sum(saldo_esperado))
            ELSE (0)::numeric
        END AS imor_proyectado,
        CASE
            WHEN (sum(saldo_esperado) > (0)::numeric) THEN (sum(
            CASE
                WHEN ((estado_markov)::text = 'P'::text) THEN saldo_esperado
                ELSE (0)::numeric
            END) / sum(saldo_esperado))
            ELSE (0)::numeric
        END AS perdida_proyectada_sobre_saldo
   FROM siarc.tb_proyeccion_markov
  GROUP BY horizonte_meses
  ORDER BY horizonte_meses;


--
-- Name: vw_resumen_markov_ia; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_resumen_markov_ia AS
 SELECT horizonte_meses,
    sum(creditos_esperados) AS creditos_totales_esperados,
    sum(saldo_esperado) AS saldo_total_esperado,
    sum(
        CASE
            WHEN ((estado_markov)::text = 'V'::text) THEN saldo_esperado
            ELSE (0)::numeric
        END) AS saldo_vigente_esperado,
    sum(
        CASE
            WHEN ((estado_markov)::text = ANY ((ARRAY['M1'::character varying, 'M2'::character varying, 'M3'::character varying, 'M4'::character varying])::text[])) THEN saldo_esperado
            ELSE (0)::numeric
        END) AS saldo_mora_esperado,
    sum(
        CASE
            WHEN ((estado_markov)::text = 'P'::text) THEN saldo_esperado
            ELSE (0)::numeric
        END) AS saldo_perdida_esperado,
        CASE
            WHEN (sum(saldo_esperado) > (0)::numeric) THEN (sum(
            CASE
                WHEN ((estado_markov)::text = ANY ((ARRAY['M1'::character varying, 'M2'::character varying, 'M3'::character varying, 'M4'::character varying])::text[])) THEN saldo_esperado
                ELSE (0)::numeric
            END) / sum(saldo_esperado))
            ELSE (0)::numeric
        END AS imor_proyectado_ia,
        CASE
            WHEN (sum(saldo_esperado) > (0)::numeric) THEN (sum(
            CASE
                WHEN ((estado_markov)::text = 'P'::text) THEN saldo_esperado
                ELSE (0)::numeric
            END) / sum(saldo_esperado))
            ELSE (0)::numeric
        END AS perdida_proyectada_sobre_saldo_ia
   FROM siarc.tb_proyeccion_markov_ia
  GROUP BY horizonte_meses
  ORDER BY horizonte_meses;


--
-- Name: vw_resumen_mv_riesgo; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_resumen_mv_riesgo AS
 SELECT count(*) AS total_creditos,
    sum(saldo_actual) AS saldo_total,
    sum(
        CASE
            WHEN (dias_atraso > 0) THEN saldo_actual
            ELSE (0)::numeric
        END) AS saldo_vencido,
    sum(
        CASE
            WHEN (dias_atraso = 0) THEN saldo_actual
            ELSE (0)::numeric
        END) AS saldo_vigente,
    sum(perdida_esperada) AS perdida_esperada_total,
    sum(reserva_estimada_siarc) AS reserva_estimada_total,
    avg(pd) AS pd_promedio,
    avg(lgd) AS lgd_promedio,
    avg(score_riesgo) AS score_promedio,
    sum(
        CASE
            WHEN (semaforo = 'ROJO'::text) THEN 1
            ELSE 0
        END) AS creditos_rojos,
    sum(
        CASE
            WHEN (semaforo = 'AMARILLO'::text) THEN 1
            ELSE 0
        END) AS creditos_amarillos,
    sum(
        CASE
            WHEN (semaforo = 'VERDE'::text) THEN 1
            ELSE 0
        END) AS creditos_verdes
   FROM siarc.mv_riesgo_cartera;


--
-- Name: vw_resumen_regulatorio; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_resumen_regulatorio AS
 SELECT etapa_riesgo_siarc,
    count(*) AS total_creditos,
    sum(saldo_actual) AS saldo_total,
    sum(reserva_regulatoria) AS reserva_requerida,
    sum(perdida_esperada) AS perdida_esperada
   FROM siarc.vw_cnbv_riesgo
  GROUP BY etapa_riesgo_siarc;


--
-- Name: vw_saldo_credito_originado; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_saldo_credito_originado AS
 SELECT c.id_credito_originado,
    c.codigo_credito,
    c.nombre_acreditado,
    c.monto_aprobado,
    c.saldo_actual,
    c.estatus_credito,
    count(cal.id_calendario) AS pagos_programados,
    sum(
        CASE
            WHEN ((cal.estatus_pago)::text = 'PAGADO'::text) THEN 1
            ELSE 0
        END) AS pagos_realizados,
    sum(
        CASE
            WHEN ((cal.estatus_pago)::text = ANY ((ARRAY['PENDIENTE'::character varying, 'PARCIAL'::character varying])::text[])) THEN 1
            ELSE 0
        END) AS pagos_pendientes,
    sum(
        CASE
            WHEN ((cal.estatus_pago)::text = 'PAGADO'::text) THEN cal.pago_programado
            ELSE (0)::numeric
        END) AS monto_pagado_programado,
    sum(
        CASE
            WHEN ((cal.estatus_pago)::text = ANY ((ARRAY['PENDIENTE'::character varying, 'PARCIAL'::character varying])::text[])) THEN cal.pago_programado
            ELSE (0)::numeric
        END) AS monto_pendiente_programado
   FROM (siarc.tb_credito_originado c
     LEFT JOIN siarc.tb_credito_calendario cal ON ((c.id_credito_originado = cal.id_credito_originado)))
  GROUP BY c.id_credito_originado, c.codigo_credito, c.nombre_acreditado, c.monto_aprobado, c.saldo_actual, c.estatus_credito;


--
-- Name: vw_semaforo_riesgo; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_semaforo_riesgo AS
 SELECT COALESCE(semaforo, 'SIN EVALUAR'::text) AS semaforo,
    count(*) AS total_creditos,
    sum(saldo_actual) AS saldo_total,
    avg(score_riesgo) AS score_promedio,
    avg(pd) AS pd_promedio,
    sum(perdida_esperada_calculada) AS perdida_esperada_total
   FROM siarc.vw_cartera_riesgo
  GROUP BY COALESCE(semaforo, 'SIN EVALUAR'::text);


--
-- Name: vw_solicitudes_credito_enriquecidas; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_solicitudes_credito_enriquecidas AS
 SELECT s.id_solicitud,
    s.folio_solicitud,
    s.fecha_solicitud,
    s.nombre,
    s.paterno,
    s.materno,
    s.curp,
    s.rfc,
    s.telefono,
    s.correo,
    s.estado,
    s.municipio,
    s.localidad,
    s.domicilio,
    s.actividad_economica,
    s.ingresos_mensuales,
    s.egresos_mensuales,
    s.producto_solicitado,
    s.destino_credito,
    s.monto_solicitado,
    s.plazo_meses,
    s.tasa_interes_anual,
    s.tipo_garantia,
    s.valor_garantia,
    s.estatus,
    s.score_preliminar,
    s.semaforo_preliminar,
    s.monto_recomendado,
    s.dictamen_preliminar,
    s.fecha_actualizacion,
    s.clave_producto,
    s.clave_actividad,
    s.clave_destino,
    s.clave_tipo_garantia,
    p.nombre_producto,
    p.monto_minimo AS producto_monto_minimo,
    p.monto_maximo AS producto_monto_maximo,
    p.plazo_minimo_meses AS producto_plazo_minimo,
    p.plazo_maximo_meses AS producto_plazo_maximo,
    p.tasa_anual_base AS producto_tasa_base,
    a.nombre_actividad,
    a.sector AS sector_actividad,
    g.nombre_garantia,
    g.factor_lgd AS lgd_catalogo,
    d.nombre_destino
   FROM ((((siarc.tb_solicitud_credito s
     LEFT JOIN siarc.cat_producto_credito p ON (((s.clave_producto)::text = (p.clave)::text)))
     LEFT JOIN siarc.cat_actividad_economica a ON (((s.clave_actividad)::text = (a.clave)::text)))
     LEFT JOIN siarc.cat_tipo_garantia_credito g ON (((s.clave_tipo_garantia)::text = (g.clave)::text)))
     LEFT JOIN siarc.cat_destino_credito d ON (((s.clave_destino)::text = (d.clave)::text)));


--
-- Name: vw_top_riesgos; Type: VIEW; Schema: siarc; Owner: -
--

CREATE VIEW siarc.vw_top_riesgos AS
 SELECT id_credito,
    codigo_credito_externo,
    id_cliente,
    codigo_cliente_externo,
    nombre_cliente,
    rfc,
    curp,
    tipo_persona,
    actividad_economica,
    estado,
    municipio,
    nombre_producto,
    nombre_sucursal,
    estado_credito,
    frecuencia_pago,
    fecha_otorgamiento,
    fecha_vencimiento,
    plazo_meses,
    monto_original,
    saldo_actual,
    saldo_capital,
    saldo_interes,
    saldo_moratorio,
    tasa_interes_anual,
    dias_atraso,
    numero_pagos_pactados,
    numero_pagos_realizados,
    fecha_ultimo_pago,
    monto_ultimo_pago,
    reestructurado,
    castigado,
    porcentaje_amortizado,
    avance_pagos,
    bucket_atraso,
    valor_garantia_total,
    valor_recuperable_garantia,
    cobertura_garantia,
    fecha_evaluacion,
    score_riesgo,
    pd,
    lgd,
    ead,
    perdida_esperada,
    clasificacion_riesgo,
    semaforo,
    dictamen,
    perdida_esperada_calculada,
    perdida_esperada_sobre_saldo,
    etapa_riesgo_siarc,
    clasificacion_cartera_siarc,
    reserva_estimada_siarc,
    fecha_generacion
   FROM siarc.mv_riesgo_cartera
  ORDER BY perdida_esperada DESC;


--
-- Name: cat_actividad_economica id_actividad; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_actividad_economica ALTER COLUMN id_actividad SET DEFAULT nextval('siarc.cat_actividad_economica_id_actividad_seq'::regclass);


--
-- Name: cat_clasificacion_riesgo id_clasificacion_riesgo; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_clasificacion_riesgo ALTER COLUMN id_clasificacion_riesgo SET DEFAULT nextval('siarc.cat_clasificacion_riesgo_id_clasificacion_riesgo_seq'::regclass);


--
-- Name: cat_cuenta_contable id_cuenta; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_cuenta_contable ALTER COLUMN id_cuenta SET DEFAULT nextval('siarc.cat_cuenta_contable_id_cuenta_seq'::regclass);


--
-- Name: cat_decision_comite id_decision; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_decision_comite ALTER COLUMN id_decision SET DEFAULT nextval('siarc.cat_decision_comite_id_decision_seq'::regclass);


--
-- Name: cat_destino_credito id_destino; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_destino_credito ALTER COLUMN id_destino SET DEFAULT nextval('siarc.cat_destino_credito_id_destino_seq'::regclass);


--
-- Name: cat_escenario_stress id_escenario; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_escenario_stress ALTER COLUMN id_escenario SET DEFAULT nextval('siarc.cat_escenario_stress_id_escenario_seq'::regclass);


--
-- Name: cat_estado_credito id_estado_credito; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_estado_credito ALTER COLUMN id_estado_credito SET DEFAULT nextval('siarc.cat_estado_credito_id_estado_credito_seq'::regclass);


--
-- Name: cat_estatus_solicitud id_estatus; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_estatus_solicitud ALTER COLUMN id_estatus SET DEFAULT nextval('siarc.cat_estatus_solicitud_id_estatus_seq'::regclass);


--
-- Name: cat_etapa_riesgo id_etapa_riesgo; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_etapa_riesgo ALTER COLUMN id_etapa_riesgo SET DEFAULT nextval('siarc.cat_etapa_riesgo_id_etapa_riesgo_seq'::regclass);


--
-- Name: cat_evento_contable id_evento; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_evento_contable ALTER COLUMN id_evento SET DEFAULT nextval('siarc.cat_evento_contable_id_evento_seq'::regclass);


--
-- Name: cat_fondo_garantia id_fondo; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_fondo_garantia ALTER COLUMN id_fondo SET DEFAULT nextval('siarc.cat_fondo_garantia_id_fondo_seq'::regclass);


--
-- Name: cat_frecuencia_pago id_frecuencia_pago; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_frecuencia_pago ALTER COLUMN id_frecuencia_pago SET DEFAULT nextval('siarc.cat_frecuencia_pago_id_frecuencia_pago_seq'::regclass);


--
-- Name: cat_mitigante_riesgo_agro id_mitigante; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_mitigante_riesgo_agro ALTER COLUMN id_mitigante SET DEFAULT nextval('siarc.cat_mitigante_riesgo_agro_id_mitigante_seq'::regclass);


--
-- Name: cat_parametro_reserva_ifrs9 id_parametro; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_parametro_reserva_ifrs9 ALTER COLUMN id_parametro SET DEFAULT nextval('siarc.cat_parametro_reserva_ifrs9_id_parametro_seq'::regclass);


--
-- Name: cat_producto id_producto; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_producto ALTER COLUMN id_producto SET DEFAULT nextval('siarc.cat_producto_id_producto_seq'::regclass);


--
-- Name: cat_producto_credito id_producto; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_producto_credito ALTER COLUMN id_producto SET DEFAULT nextval('siarc.cat_producto_credito_id_producto_seq'::regclass);


--
-- Name: cat_reserva_riesgo id_reserva; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_reserva_riesgo ALTER COLUMN id_reserva SET DEFAULT nextval('siarc.cat_reserva_riesgo_id_reserva_seq'::regclass);


--
-- Name: cat_resultado_gestion_cobranza id_resultado; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_resultado_gestion_cobranza ALTER COLUMN id_resultado SET DEFAULT nextval('siarc.cat_resultado_gestion_cobranza_id_resultado_seq'::regclass);


--
-- Name: cat_semaforo id_semaforo; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_semaforo ALTER COLUMN id_semaforo SET DEFAULT nextval('siarc.cat_semaforo_id_semaforo_seq'::regclass);


--
-- Name: cat_sucursal id_sucursal; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_sucursal ALTER COLUMN id_sucursal SET DEFAULT nextval('siarc.cat_sucursal_id_sucursal_seq'::regclass);


--
-- Name: cat_tipo_garantia id_tipo_garantia; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_tipo_garantia ALTER COLUMN id_tipo_garantia SET DEFAULT nextval('siarc.cat_tipo_garantia_id_tipo_garantia_seq'::regclass);


--
-- Name: cat_tipo_garantia_credito id_tipo_garantia_credito; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_tipo_garantia_credito ALTER COLUMN id_tipo_garantia_credito SET DEFAULT nextval('siarc.cat_tipo_garantia_credito_id_tipo_garantia_credito_seq'::regclass);


--
-- Name: cat_tipo_gestion_cobranza id_tipo_gestion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_tipo_gestion_cobranza ALTER COLUMN id_tipo_gestion SET DEFAULT nextval('siarc.cat_tipo_gestion_cobranza_id_tipo_gestion_seq'::regclass);


--
-- Name: tb_alerta_temprana id_alerta; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_alerta_temprana ALTER COLUMN id_alerta SET DEFAULT nextval('siarc.tb_alerta_temprana_id_alerta_seq'::regclass);


--
-- Name: tb_analisis_credito id_analisis; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_analisis_credito ALTER COLUMN id_analisis SET DEFAULT nextval('siarc.tb_analisis_credito_id_analisis_seq'::regclass);


--
-- Name: tb_api_key id_api_key; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_api_key ALTER COLUMN id_api_key SET DEFAULT nextval('siarc.tb_api_key_id_api_key_seq'::regclass);


--
-- Name: tb_api_log id_log; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_api_log ALTER COLUMN id_log SET DEFAULT nextval('siarc.tb_api_log_id_log_seq'::regclass);


--
-- Name: tb_bitacora_auditoria id_evento; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_bitacora_auditoria ALTER COLUMN id_evento SET DEFAULT nextval('siarc.tb_bitacora_auditoria_id_evento_seq'::regclass);


--
-- Name: tb_clasificacion_cartera id_clasificacion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_clasificacion_cartera ALTER COLUMN id_clasificacion SET DEFAULT nextval('siarc.tb_clasificacion_cartera_id_clasificacion_seq'::regclass);


--
-- Name: tb_cliente id_cliente; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_cliente ALTER COLUMN id_cliente SET DEFAULT nextval('siarc.tb_cliente_id_cliente_seq'::regclass);


--
-- Name: tb_comite_credito id_comite; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_comite_credito ALTER COLUMN id_comite SET DEFAULT nextval('siarc.tb_comite_credito_id_comite_seq'::regclass);


--
-- Name: tb_credito id_credito; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito ALTER COLUMN id_credito SET DEFAULT nextval('siarc.tb_credito_id_credito_seq'::regclass);


--
-- Name: tb_credito_calendario id_calendario; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_calendario ALTER COLUMN id_calendario SET DEFAULT nextval('siarc.tb_credito_calendario_id_calendario_seq'::regclass);


--
-- Name: tb_credito_cobertura_garantia id_cobertura; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_cobertura_garantia ALTER COLUMN id_cobertura SET DEFAULT nextval('siarc.tb_credito_cobertura_garantia_id_cobertura_seq'::regclass);


--
-- Name: tb_credito_mitigante_riesgo id_credito_mitigante; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_mitigante_riesgo ALTER COLUMN id_credito_mitigante SET DEFAULT nextval('siarc.tb_credito_mitigante_riesgo_id_credito_mitigante_seq'::regclass);


--
-- Name: tb_credito_originado id_credito_originado; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_originado ALTER COLUMN id_credito_originado SET DEFAULT nextval('siarc.tb_credito_originado_id_credito_originado_seq'::regclass);


--
-- Name: tb_credito_pago id_pago; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_pago ALTER COLUMN id_pago SET DEFAULT nextval('siarc.tb_credito_pago_id_pago_seq'::regclass);


--
-- Name: tb_estado_credito_historico id_estado; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_estado_credito_historico ALTER COLUMN id_estado SET DEFAULT nextval('siarc.tb_estado_credito_historico_id_estado_seq'::regclass);


--
-- Name: tb_garantia id_garantia; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_garantia ALTER COLUMN id_garantia SET DEFAULT nextval('siarc.tb_garantia_id_garantia_seq'::regclass);


--
-- Name: tb_gestion_cobranza id_gestion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_gestion_cobranza ALTER COLUMN id_gestion SET DEFAULT nextval('siarc.tb_gestion_cobranza_id_gestion_seq'::regclass);


--
-- Name: tb_log_acceso id_log; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_log_acceso ALTER COLUMN id_log SET DEFAULT nextval('siarc.tb_log_acceso_id_log_seq'::regclass);


--
-- Name: tb_map_cliente id_map; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_map_cliente ALTER COLUMN id_map SET DEFAULT nextval('siarc.tb_map_cliente_id_map_seq'::regclass);


--
-- Name: tb_map_credito id_map; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_map_credito ALTER COLUMN id_map SET DEFAULT nextval('siarc.tb_map_credito_id_map_seq'::regclass);


--
-- Name: tb_markov_historico id_historico; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_markov_historico ALTER COLUMN id_historico SET DEFAULT nextval('siarc.tb_markov_historico_id_historico_seq'::regclass);


--
-- Name: tb_matriz_markov_calculada id_matriz; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_matriz_markov_calculada ALTER COLUMN id_matriz SET DEFAULT nextval('siarc.tb_matriz_markov_calculada_id_matriz_seq'::regclass);


--
-- Name: tb_matriz_transicion id_transicion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_matriz_transicion ALTER COLUMN id_transicion SET DEFAULT nextval('siarc.tb_matriz_transicion_id_transicion_seq'::regclass);


--
-- Name: tb_mifos_pago id_pago; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_mifos_pago ALTER COLUMN id_pago SET DEFAULT nextval('siarc.tb_mifos_pago_id_pago_seq'::regclass);


--
-- Name: tb_modelo_riesgo id_modelo; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_modelo_riesgo ALTER COLUMN id_modelo SET DEFAULT nextval('siarc.tb_modelo_riesgo_id_modelo_seq'::regclass);


--
-- Name: tb_modelo_variable id_modelo_variable; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_modelo_variable ALTER COLUMN id_modelo_variable SET DEFAULT nextval('siarc.tb_modelo_variable_id_modelo_variable_seq'::regclass);


--
-- Name: tb_monte_carlo id_simulacion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_monte_carlo ALTER COLUMN id_simulacion SET DEFAULT nextval('siarc.tb_monte_carlo_id_simulacion_seq'::regclass);


--
-- Name: tb_montecarlo_cartera id_simulacion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_montecarlo_cartera ALTER COLUMN id_simulacion SET DEFAULT nextval('siarc.tb_montecarlo_cartera_id_simulacion_seq'::regclass);


--
-- Name: tb_montecarlo_escenario id_escenario; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_montecarlo_escenario ALTER COLUMN id_escenario SET DEFAULT nextval('siarc.tb_montecarlo_escenario_id_escenario_seq'::regclass);


--
-- Name: tb_montecarlo_ia_cartera id_simulacion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_montecarlo_ia_cartera ALTER COLUMN id_simulacion SET DEFAULT nextval('siarc.tb_montecarlo_ia_cartera_id_simulacion_seq'::regclass);


--
-- Name: tb_montecarlo_ia_escenario id_escenario; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_montecarlo_ia_escenario ALTER COLUMN id_escenario SET DEFAULT nextval('siarc.tb_montecarlo_ia_escenario_id_escenario_seq'::regclass);


--
-- Name: tb_pago id_pago; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_pago ALTER COLUMN id_pago SET DEFAULT nextval('siarc.tb_pago_id_pago_seq'::regclass);


--
-- Name: tb_pago_garantia_fondo id_pago_garantia; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_pago_garantia_fondo ALTER COLUMN id_pago_garantia SET DEFAULT nextval('siarc.tb_pago_garantia_fondo_id_pago_garantia_seq'::regclass);


--
-- Name: tb_perdida_esperada id_perdida; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_perdida_esperada ALTER COLUMN id_perdida SET DEFAULT nextval('siarc.tb_perdida_esperada_id_perdida_seq'::regclass);


--
-- Name: tb_poliza_contable id_poliza; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_poliza_contable ALTER COLUMN id_poliza SET DEFAULT nextval('siarc.tb_poliza_contable_id_poliza_seq'::regclass);


--
-- Name: tb_poliza_detalle id_detalle; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_poliza_detalle ALTER COLUMN id_detalle SET DEFAULT nextval('siarc.tb_poliza_detalle_id_detalle_seq'::regclass);


--
-- Name: tb_proyeccion_markov id_proyeccion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_proyeccion_markov ALTER COLUMN id_proyeccion SET DEFAULT nextval('siarc.tb_proyeccion_markov_id_proyeccion_seq'::regclass);


--
-- Name: tb_proyeccion_markov_ia id_proyeccion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_proyeccion_markov_ia ALTER COLUMN id_proyeccion SET DEFAULT nextval('siarc.tb_proyeccion_markov_ia_id_proyeccion_seq'::regclass);


--
-- Name: tb_reclamacion_garantia id_reclamacion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_reclamacion_garantia ALTER COLUMN id_reclamacion SET DEFAULT nextval('siarc.tb_reclamacion_garantia_id_reclamacion_seq'::regclass);


--
-- Name: tb_recuperacion_post_garantia id_recuperacion; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_recuperacion_post_garantia ALTER COLUMN id_recuperacion SET DEFAULT nextval('siarc.tb_recuperacion_post_garantia_id_recuperacion_seq'::regclass);


--
-- Name: tb_resultado_ia_pd id_resultado; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_ia_pd ALTER COLUMN id_resultado SET DEFAULT nextval('siarc.tb_resultado_ia_pd_id_resultado_seq'::regclass);


--
-- Name: tb_resultado_riesgo id_resultado; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_riesgo ALTER COLUMN id_resultado SET DEFAULT nextval('siarc.tb_resultado_riesgo_id_resultado_seq'::regclass);


--
-- Name: tb_resultado_variable id_resultado_variable; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_variable ALTER COLUMN id_resultado_variable SET DEFAULT nextval('siarc.tb_resultado_variable_id_resultado_variable_seq'::regclass);


--
-- Name: tb_snapshot_cartera id_snapshot; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_snapshot_cartera ALTER COLUMN id_snapshot SET DEFAULT nextval('siarc.tb_snapshot_cartera_id_snapshot_seq'::regclass);


--
-- Name: tb_solicitud_credito id_solicitud; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_credito ALTER COLUMN id_solicitud SET DEFAULT nextval('siarc.tb_solicitud_credito_id_solicitud_seq'::regclass);


--
-- Name: tb_solicitud_historial id_historial; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_historial ALTER COLUMN id_historial SET DEFAULT nextval('siarc.tb_solicitud_historial_id_historial_seq'::regclass);


--
-- Name: tb_stress_test id_stress; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_stress_test ALTER COLUMN id_stress SET DEFAULT nextval('siarc.tb_stress_test_id_stress_seq'::regclass);


--
-- Name: tb_sync_error id_error; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_sync_error ALTER COLUMN id_error SET DEFAULT nextval('siarc.tb_sync_error_id_error_seq'::regclass);


--
-- Name: tb_sync_proceso id_sync; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_sync_proceso ALTER COLUMN id_sync SET DEFAULT nextval('siarc.tb_sync_proceso_id_sync_seq'::regclass);


--
-- Name: tb_usuario id_usuario; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_usuario ALTER COLUMN id_usuario SET DEFAULT nextval('siarc.tb_usuario_id_usuario_seq'::regclass);


--
-- Name: tb_variable_riesgo id_variable; Type: DEFAULT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_variable_riesgo ALTER COLUMN id_variable SET DEFAULT nextval('siarc.tb_variable_riesgo_id_variable_seq'::regclass);


--
-- Name: cat_actividad_economica cat_actividad_economica_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_actividad_economica
    ADD CONSTRAINT cat_actividad_economica_clave_key UNIQUE (clave);


--
-- Name: cat_actividad_economica cat_actividad_economica_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_actividad_economica
    ADD CONSTRAINT cat_actividad_economica_pkey PRIMARY KEY (id_actividad);


--
-- Name: cat_clasificacion_riesgo cat_clasificacion_riesgo_clasificacion_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_clasificacion_riesgo
    ADD CONSTRAINT cat_clasificacion_riesgo_clasificacion_key UNIQUE (clasificacion);


--
-- Name: cat_clasificacion_riesgo cat_clasificacion_riesgo_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_clasificacion_riesgo
    ADD CONSTRAINT cat_clasificacion_riesgo_pkey PRIMARY KEY (id_clasificacion_riesgo);


--
-- Name: cat_cuenta_contable cat_cuenta_contable_cuenta_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_cuenta_contable
    ADD CONSTRAINT cat_cuenta_contable_cuenta_key UNIQUE (cuenta);


--
-- Name: cat_cuenta_contable cat_cuenta_contable_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_cuenta_contable
    ADD CONSTRAINT cat_cuenta_contable_pkey PRIMARY KEY (id_cuenta);


--
-- Name: cat_decision_comite cat_decision_comite_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_decision_comite
    ADD CONSTRAINT cat_decision_comite_clave_key UNIQUE (clave);


--
-- Name: cat_decision_comite cat_decision_comite_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_decision_comite
    ADD CONSTRAINT cat_decision_comite_pkey PRIMARY KEY (id_decision);


--
-- Name: cat_destino_credito cat_destino_credito_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_destino_credito
    ADD CONSTRAINT cat_destino_credito_clave_key UNIQUE (clave);


--
-- Name: cat_destino_credito cat_destino_credito_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_destino_credito
    ADD CONSTRAINT cat_destino_credito_pkey PRIMARY KEY (id_destino);


--
-- Name: cat_escenario_stress cat_escenario_stress_escenario_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_escenario_stress
    ADD CONSTRAINT cat_escenario_stress_escenario_key UNIQUE (escenario);


--
-- Name: cat_escenario_stress cat_escenario_stress_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_escenario_stress
    ADD CONSTRAINT cat_escenario_stress_pkey PRIMARY KEY (id_escenario);


--
-- Name: cat_estado_credito cat_estado_credito_estado_credito_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_estado_credito
    ADD CONSTRAINT cat_estado_credito_estado_credito_key UNIQUE (estado_credito);


--
-- Name: cat_estado_credito cat_estado_credito_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_estado_credito
    ADD CONSTRAINT cat_estado_credito_pkey PRIMARY KEY (id_estado_credito);


--
-- Name: cat_estatus_solicitud cat_estatus_solicitud_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_estatus_solicitud
    ADD CONSTRAINT cat_estatus_solicitud_clave_key UNIQUE (clave);


--
-- Name: cat_estatus_solicitud cat_estatus_solicitud_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_estatus_solicitud
    ADD CONSTRAINT cat_estatus_solicitud_pkey PRIMARY KEY (id_estatus);


--
-- Name: cat_etapa_riesgo cat_etapa_riesgo_etapa_riesgo_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_etapa_riesgo
    ADD CONSTRAINT cat_etapa_riesgo_etapa_riesgo_key UNIQUE (etapa_riesgo);


--
-- Name: cat_etapa_riesgo cat_etapa_riesgo_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_etapa_riesgo
    ADD CONSTRAINT cat_etapa_riesgo_pkey PRIMARY KEY (id_etapa_riesgo);


--
-- Name: cat_evento_contable cat_evento_contable_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_evento_contable
    ADD CONSTRAINT cat_evento_contable_clave_key UNIQUE (clave);


--
-- Name: cat_evento_contable cat_evento_contable_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_evento_contable
    ADD CONSTRAINT cat_evento_contable_pkey PRIMARY KEY (id_evento);


--
-- Name: cat_fondo_garantia cat_fondo_garantia_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_fondo_garantia
    ADD CONSTRAINT cat_fondo_garantia_clave_key UNIQUE (clave);


--
-- Name: cat_fondo_garantia cat_fondo_garantia_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_fondo_garantia
    ADD CONSTRAINT cat_fondo_garantia_pkey PRIMARY KEY (id_fondo);


--
-- Name: cat_frecuencia_pago cat_frecuencia_pago_frecuencia_pago_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_frecuencia_pago
    ADD CONSTRAINT cat_frecuencia_pago_frecuencia_pago_key UNIQUE (frecuencia_pago);


--
-- Name: cat_frecuencia_pago cat_frecuencia_pago_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_frecuencia_pago
    ADD CONSTRAINT cat_frecuencia_pago_pkey PRIMARY KEY (id_frecuencia_pago);


--
-- Name: cat_mitigante_riesgo_agro cat_mitigante_riesgo_agro_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_mitigante_riesgo_agro
    ADD CONSTRAINT cat_mitigante_riesgo_agro_clave_key UNIQUE (clave);


--
-- Name: cat_mitigante_riesgo_agro cat_mitigante_riesgo_agro_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_mitigante_riesgo_agro
    ADD CONSTRAINT cat_mitigante_riesgo_agro_pkey PRIMARY KEY (id_mitigante);


--
-- Name: cat_parametro_reserva_ifrs9 cat_parametro_reserva_ifrs9_etapa_riesgo_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_parametro_reserva_ifrs9
    ADD CONSTRAINT cat_parametro_reserva_ifrs9_etapa_riesgo_key UNIQUE (etapa_riesgo);


--
-- Name: cat_parametro_reserva_ifrs9 cat_parametro_reserva_ifrs9_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_parametro_reserva_ifrs9
    ADD CONSTRAINT cat_parametro_reserva_ifrs9_pkey PRIMARY KEY (id_parametro);


--
-- Name: cat_producto cat_producto_codigo_producto_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_producto
    ADD CONSTRAINT cat_producto_codigo_producto_key UNIQUE (codigo_producto);


--
-- Name: cat_producto_credito cat_producto_credito_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_producto_credito
    ADD CONSTRAINT cat_producto_credito_clave_key UNIQUE (clave);


--
-- Name: cat_producto_credito cat_producto_credito_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_producto_credito
    ADD CONSTRAINT cat_producto_credito_pkey PRIMARY KEY (id_producto);


--
-- Name: cat_producto cat_producto_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_producto
    ADD CONSTRAINT cat_producto_pkey PRIMARY KEY (id_producto);


--
-- Name: cat_reserva_riesgo cat_reserva_riesgo_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_reserva_riesgo
    ADD CONSTRAINT cat_reserva_riesgo_pkey PRIMARY KEY (id_reserva);


--
-- Name: cat_resultado_gestion_cobranza cat_resultado_gestion_cobranza_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_resultado_gestion_cobranza
    ADD CONSTRAINT cat_resultado_gestion_cobranza_clave_key UNIQUE (clave);


--
-- Name: cat_resultado_gestion_cobranza cat_resultado_gestion_cobranza_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_resultado_gestion_cobranza
    ADD CONSTRAINT cat_resultado_gestion_cobranza_pkey PRIMARY KEY (id_resultado);


--
-- Name: cat_rol_usuario cat_rol_usuario_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_rol_usuario
    ADD CONSTRAINT cat_rol_usuario_pkey PRIMARY KEY (rol);


--
-- Name: cat_semaforo cat_semaforo_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_semaforo
    ADD CONSTRAINT cat_semaforo_pkey PRIMARY KEY (id_semaforo);


--
-- Name: cat_semaforo cat_semaforo_semaforo_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_semaforo
    ADD CONSTRAINT cat_semaforo_semaforo_key UNIQUE (semaforo);


--
-- Name: cat_sucursal cat_sucursal_codigo_sucursal_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_sucursal
    ADD CONSTRAINT cat_sucursal_codigo_sucursal_key UNIQUE (codigo_sucursal);


--
-- Name: cat_sucursal cat_sucursal_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_sucursal
    ADD CONSTRAINT cat_sucursal_pkey PRIMARY KEY (id_sucursal);


--
-- Name: cat_tipo_garantia_credito cat_tipo_garantia_credito_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_tipo_garantia_credito
    ADD CONSTRAINT cat_tipo_garantia_credito_clave_key UNIQUE (clave);


--
-- Name: cat_tipo_garantia_credito cat_tipo_garantia_credito_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_tipo_garantia_credito
    ADD CONSTRAINT cat_tipo_garantia_credito_pkey PRIMARY KEY (id_tipo_garantia_credito);


--
-- Name: cat_tipo_garantia cat_tipo_garantia_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_tipo_garantia
    ADD CONSTRAINT cat_tipo_garantia_pkey PRIMARY KEY (id_tipo_garantia);


--
-- Name: cat_tipo_garantia cat_tipo_garantia_tipo_garantia_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_tipo_garantia
    ADD CONSTRAINT cat_tipo_garantia_tipo_garantia_key UNIQUE (tipo_garantia);


--
-- Name: cat_tipo_gestion_cobranza cat_tipo_gestion_cobranza_clave_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_tipo_gestion_cobranza
    ADD CONSTRAINT cat_tipo_gestion_cobranza_clave_key UNIQUE (clave);


--
-- Name: cat_tipo_gestion_cobranza cat_tipo_gestion_cobranza_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.cat_tipo_gestion_cobranza
    ADD CONSTRAINT cat_tipo_gestion_cobranza_pkey PRIMARY KEY (id_tipo_gestion);


--
-- Name: tb_alerta_temprana tb_alerta_temprana_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_alerta_temprana
    ADD CONSTRAINT tb_alerta_temprana_pkey PRIMARY KEY (id_alerta);


--
-- Name: tb_analisis_credito tb_analisis_credito_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_analisis_credito
    ADD CONSTRAINT tb_analisis_credito_pkey PRIMARY KEY (id_analisis);


--
-- Name: tb_api_key tb_api_key_api_key_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_api_key
    ADD CONSTRAINT tb_api_key_api_key_key UNIQUE (api_key);


--
-- Name: tb_api_key tb_api_key_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_api_key
    ADD CONSTRAINT tb_api_key_pkey PRIMARY KEY (id_api_key);


--
-- Name: tb_api_log tb_api_log_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_api_log
    ADD CONSTRAINT tb_api_log_pkey PRIMARY KEY (id_log);


--
-- Name: tb_bitacora_auditoria tb_bitacora_auditoria_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_bitacora_auditoria
    ADD CONSTRAINT tb_bitacora_auditoria_pkey PRIMARY KEY (id_evento);


--
-- Name: tb_clasificacion_cartera tb_clasificacion_cartera_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_clasificacion_cartera
    ADD CONSTRAINT tb_clasificacion_cartera_pkey PRIMARY KEY (id_clasificacion);


--
-- Name: tb_cliente tb_cliente_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_cliente
    ADD CONSTRAINT tb_cliente_pkey PRIMARY KEY (id_cliente);


--
-- Name: tb_comite_credito tb_comite_credito_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_comite_credito
    ADD CONSTRAINT tb_comite_credito_pkey PRIMARY KEY (id_comite);


--
-- Name: tb_credito_calendario tb_credito_calendario_id_credito_originado_numero_pago_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_calendario
    ADD CONSTRAINT tb_credito_calendario_id_credito_originado_numero_pago_key UNIQUE (id_credito_originado, numero_pago);


--
-- Name: tb_credito_calendario tb_credito_calendario_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_calendario
    ADD CONSTRAINT tb_credito_calendario_pkey PRIMARY KEY (id_calendario);


--
-- Name: tb_credito_cobertura_garantia tb_credito_cobertura_garantia_id_credito_originado_id_fondo_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_cobertura_garantia
    ADD CONSTRAINT tb_credito_cobertura_garantia_id_credito_originado_id_fondo_key UNIQUE (id_credito_originado, id_fondo);


--
-- Name: tb_credito_cobertura_garantia tb_credito_cobertura_garantia_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_cobertura_garantia
    ADD CONSTRAINT tb_credito_cobertura_garantia_pkey PRIMARY KEY (id_cobertura);


--
-- Name: tb_credito_mitigante_riesgo tb_credito_mitigante_riesgo_id_credito_originado_id_mitigan_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_mitigante_riesgo
    ADD CONSTRAINT tb_credito_mitigante_riesgo_id_credito_originado_id_mitigan_key UNIQUE (id_credito_originado, id_mitigante);


--
-- Name: tb_credito_mitigante_riesgo tb_credito_mitigante_riesgo_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_mitigante_riesgo
    ADD CONSTRAINT tb_credito_mitigante_riesgo_pkey PRIMARY KEY (id_credito_mitigante);


--
-- Name: tb_credito_originado tb_credito_originado_codigo_credito_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_originado
    ADD CONSTRAINT tb_credito_originado_codigo_credito_key UNIQUE (codigo_credito);


--
-- Name: tb_credito_originado tb_credito_originado_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_originado
    ADD CONSTRAINT tb_credito_originado_pkey PRIMARY KEY (id_credito_originado);


--
-- Name: tb_credito_pago tb_credito_pago_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_pago
    ADD CONSTRAINT tb_credito_pago_pkey PRIMARY KEY (id_pago);


--
-- Name: tb_credito tb_credito_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito
    ADD CONSTRAINT tb_credito_pkey PRIMARY KEY (id_credito);


--
-- Name: tb_estado_credito_historico tb_estado_credito_historico_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_estado_credito_historico
    ADD CONSTRAINT tb_estado_credito_historico_pkey PRIMARY KEY (id_estado);


--
-- Name: tb_garantia tb_garantia_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_garantia
    ADD CONSTRAINT tb_garantia_pkey PRIMARY KEY (id_garantia);


--
-- Name: tb_gestion_cobranza tb_gestion_cobranza_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_gestion_cobranza
    ADD CONSTRAINT tb_gestion_cobranza_pkey PRIMARY KEY (id_gestion);


--
-- Name: tb_log_acceso tb_log_acceso_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_log_acceso
    ADD CONSTRAINT tb_log_acceso_pkey PRIMARY KEY (id_log);


--
-- Name: tb_map_cliente tb_map_cliente_id_mifos_cliente_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_map_cliente
    ADD CONSTRAINT tb_map_cliente_id_mifos_cliente_key UNIQUE (id_mifos_cliente);


--
-- Name: tb_map_cliente tb_map_cliente_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_map_cliente
    ADD CONSTRAINT tb_map_cliente_pkey PRIMARY KEY (id_map);


--
-- Name: tb_map_credito tb_map_credito_id_mifos_credito_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_map_credito
    ADD CONSTRAINT tb_map_credito_id_mifos_credito_key UNIQUE (id_mifos_credito);


--
-- Name: tb_map_credito tb_map_credito_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_map_credito
    ADD CONSTRAINT tb_map_credito_pkey PRIMARY KEY (id_map);


--
-- Name: tb_markov_historico tb_markov_historico_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_markov_historico
    ADD CONSTRAINT tb_markov_historico_pkey PRIMARY KEY (id_historico);


--
-- Name: tb_matriz_markov_calculada tb_matriz_markov_calculada_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_matriz_markov_calculada
    ADD CONSTRAINT tb_matriz_markov_calculada_pkey PRIMARY KEY (id_matriz);


--
-- Name: tb_matriz_transicion tb_matriz_transicion_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_matriz_transicion
    ADD CONSTRAINT tb_matriz_transicion_pkey PRIMARY KEY (id_transicion);


--
-- Name: tb_mifos_cliente tb_mifos_cliente_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_mifos_cliente
    ADD CONSTRAINT tb_mifos_cliente_pkey PRIMARY KEY (id_mifos_cliente);


--
-- Name: tb_mifos_credito tb_mifos_credito_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_mifos_credito
    ADD CONSTRAINT tb_mifos_credito_pkey PRIMARY KEY (id_mifos_credito);


--
-- Name: tb_mifos_pago tb_mifos_pago_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_mifos_pago
    ADD CONSTRAINT tb_mifos_pago_pkey PRIMARY KEY (id_pago);


--
-- Name: tb_modelo_riesgo tb_modelo_riesgo_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_modelo_riesgo
    ADD CONSTRAINT tb_modelo_riesgo_pkey PRIMARY KEY (id_modelo);


--
-- Name: tb_modelo_variable tb_modelo_variable_id_modelo_id_variable_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_modelo_variable
    ADD CONSTRAINT tb_modelo_variable_id_modelo_id_variable_key UNIQUE (id_modelo, id_variable);


--
-- Name: tb_modelo_variable tb_modelo_variable_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_modelo_variable
    ADD CONSTRAINT tb_modelo_variable_pkey PRIMARY KEY (id_modelo_variable);


--
-- Name: tb_monte_carlo tb_monte_carlo_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_monte_carlo
    ADD CONSTRAINT tb_monte_carlo_pkey PRIMARY KEY (id_simulacion);


--
-- Name: tb_montecarlo_cartera tb_montecarlo_cartera_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_montecarlo_cartera
    ADD CONSTRAINT tb_montecarlo_cartera_pkey PRIMARY KEY (id_simulacion);


--
-- Name: tb_montecarlo_escenario tb_montecarlo_escenario_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_montecarlo_escenario
    ADD CONSTRAINT tb_montecarlo_escenario_pkey PRIMARY KEY (id_escenario);


--
-- Name: tb_montecarlo_ia_cartera tb_montecarlo_ia_cartera_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_montecarlo_ia_cartera
    ADD CONSTRAINT tb_montecarlo_ia_cartera_pkey PRIMARY KEY (id_simulacion);


--
-- Name: tb_montecarlo_ia_escenario tb_montecarlo_ia_escenario_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_montecarlo_ia_escenario
    ADD CONSTRAINT tb_montecarlo_ia_escenario_pkey PRIMARY KEY (id_escenario);


--
-- Name: tb_pago_garantia_fondo tb_pago_garantia_fondo_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_pago_garantia_fondo
    ADD CONSTRAINT tb_pago_garantia_fondo_pkey PRIMARY KEY (id_pago_garantia);


--
-- Name: tb_pago tb_pago_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_pago
    ADD CONSTRAINT tb_pago_pkey PRIMARY KEY (id_pago);


--
-- Name: tb_perdida_esperada tb_perdida_esperada_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_perdida_esperada
    ADD CONSTRAINT tb_perdida_esperada_pkey PRIMARY KEY (id_perdida);


--
-- Name: tb_poliza_contable tb_poliza_contable_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_poliza_contable
    ADD CONSTRAINT tb_poliza_contable_pkey PRIMARY KEY (id_poliza);


--
-- Name: tb_poliza_detalle tb_poliza_detalle_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_poliza_detalle
    ADD CONSTRAINT tb_poliza_detalle_pkey PRIMARY KEY (id_detalle);


--
-- Name: tb_proyeccion_markov_ia tb_proyeccion_markov_ia_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_proyeccion_markov_ia
    ADD CONSTRAINT tb_proyeccion_markov_ia_pkey PRIMARY KEY (id_proyeccion);


--
-- Name: tb_proyeccion_markov tb_proyeccion_markov_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_proyeccion_markov
    ADD CONSTRAINT tb_proyeccion_markov_pkey PRIMARY KEY (id_proyeccion);


--
-- Name: tb_reclamacion_garantia tb_reclamacion_garantia_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_reclamacion_garantia
    ADD CONSTRAINT tb_reclamacion_garantia_pkey PRIMARY KEY (id_reclamacion);


--
-- Name: tb_recuperacion_post_garantia tb_recuperacion_post_garantia_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_recuperacion_post_garantia
    ADD CONSTRAINT tb_recuperacion_post_garantia_pkey PRIMARY KEY (id_recuperacion);


--
-- Name: tb_resultado_ia_pd tb_resultado_ia_pd_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_ia_pd
    ADD CONSTRAINT tb_resultado_ia_pd_pkey PRIMARY KEY (id_resultado);


--
-- Name: tb_resultado_riesgo tb_resultado_riesgo_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_riesgo
    ADD CONSTRAINT tb_resultado_riesgo_pkey PRIMARY KEY (id_resultado);


--
-- Name: tb_resultado_variable tb_resultado_variable_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_variable
    ADD CONSTRAINT tb_resultado_variable_pkey PRIMARY KEY (id_resultado_variable);


--
-- Name: tb_snapshot_cartera tb_snapshot_cartera_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_snapshot_cartera
    ADD CONSTRAINT tb_snapshot_cartera_pkey PRIMARY KEY (id_snapshot);


--
-- Name: tb_solicitud_credito tb_solicitud_credito_folio_solicitud_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_credito
    ADD CONSTRAINT tb_solicitud_credito_folio_solicitud_key UNIQUE (folio_solicitud);


--
-- Name: tb_solicitud_credito tb_solicitud_credito_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_credito
    ADD CONSTRAINT tb_solicitud_credito_pkey PRIMARY KEY (id_solicitud);


--
-- Name: tb_solicitud_historial tb_solicitud_historial_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_historial
    ADD CONSTRAINT tb_solicitud_historial_pkey PRIMARY KEY (id_historial);


--
-- Name: tb_stress_test tb_stress_test_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_stress_test
    ADD CONSTRAINT tb_stress_test_pkey PRIMARY KEY (id_stress);


--
-- Name: tb_sync_error tb_sync_error_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_sync_error
    ADD CONSTRAINT tb_sync_error_pkey PRIMARY KEY (id_error);


--
-- Name: tb_sync_proceso tb_sync_proceso_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_sync_proceso
    ADD CONSTRAINT tb_sync_proceso_pkey PRIMARY KEY (id_sync);


--
-- Name: tb_usuario tb_usuario_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_usuario
    ADD CONSTRAINT tb_usuario_pkey PRIMARY KEY (id_usuario);


--
-- Name: tb_usuario tb_usuario_usuario_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_usuario
    ADD CONSTRAINT tb_usuario_usuario_key UNIQUE (usuario);


--
-- Name: tb_variable_riesgo tb_variable_riesgo_nombre_variable_key; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_variable_riesgo
    ADD CONSTRAINT tb_variable_riesgo_nombre_variable_key UNIQUE (nombre_variable);


--
-- Name: tb_variable_riesgo tb_variable_riesgo_pkey; Type: CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_variable_riesgo
    ADD CONSTRAINT tb_variable_riesgo_pkey PRIMARY KEY (id_variable);


--
-- Name: idx_alerta_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_alerta_credito ON siarc.tb_alerta_temprana USING btree (id_credito);


--
-- Name: idx_alerta_nivel; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_alerta_nivel ON siarc.tb_alerta_temprana USING btree (nivel_alerta);


--
-- Name: idx_bitacora_fecha; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_bitacora_fecha ON siarc.tb_bitacora_auditoria USING btree (fecha_evento);


--
-- Name: idx_bitacora_modulo; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_bitacora_modulo ON siarc.tb_bitacora_auditoria USING btree (modulo);


--
-- Name: idx_bitacora_referencia; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_bitacora_referencia ON siarc.tb_bitacora_auditoria USING btree (referencia);


--
-- Name: idx_calendario_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_calendario_credito ON siarc.tb_credito_calendario USING btree (id_credito_originado);


--
-- Name: idx_calendario_estatus; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_calendario_estatus ON siarc.tb_credito_calendario USING btree (estatus_pago);


--
-- Name: idx_calendario_fecha; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_calendario_fecha ON siarc.tb_credito_calendario USING btree (fecha_vencimiento);


--
-- Name: idx_clasificacion_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_clasificacion_credito ON siarc.tb_clasificacion_cartera USING btree (id_credito);


--
-- Name: idx_cliente_codigo_externo; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_cliente_codigo_externo ON siarc.tb_cliente USING btree (codigo_cliente_externo);


--
-- Name: idx_cliente_curp; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_cliente_curp ON siarc.tb_cliente USING btree (curp);


--
-- Name: idx_cliente_rfc; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_cliente_rfc ON siarc.tb_cliente USING btree (rfc);


--
-- Name: idx_credito_cliente; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_credito_cliente ON siarc.tb_credito USING btree (id_cliente);


--
-- Name: idx_credito_codigo_externo; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_credito_codigo_externo ON siarc.tb_credito USING btree (codigo_credito_externo);


--
-- Name: idx_credito_dias_atraso; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_credito_dias_atraso ON siarc.tb_credito USING btree (dias_atraso);


--
-- Name: idx_credito_estado; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_credito_estado ON siarc.tb_credito USING btree (id_estado_credito);


--
-- Name: idx_credito_mitigante_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_credito_mitigante_credito ON siarc.tb_credito_mitigante_riesgo USING btree (id_credito_originado);


--
-- Name: idx_credito_mitigante_mitigante; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_credito_mitigante_mitigante ON siarc.tb_credito_mitigante_riesgo USING btree (id_mitigante);


--
-- Name: idx_credito_originado_codigo; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_credito_originado_codigo ON siarc.tb_credito_originado USING btree (codigo_credito);


--
-- Name: idx_credito_originado_solicitud; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_credito_originado_solicitud ON siarc.tb_credito_originado USING btree (id_solicitud);


--
-- Name: idx_dashboard_credito_estado_atraso; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_dashboard_credito_estado_atraso ON siarc.tb_credito USING btree (id_estado_credito, dias_atraso);


--
-- Name: idx_dashboard_credito_producto_saldo; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_dashboard_credito_producto_saldo ON siarc.tb_credito USING btree (id_producto, saldo_actual);


--
-- Name: idx_dashboard_riesgo_fecha_clasificacion; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_dashboard_riesgo_fecha_clasificacion ON siarc.tb_resultado_riesgo USING btree (fecha_evaluacion, clasificacion_riesgo);


--
-- Name: idx_dashboard_riesgo_fecha_semaforo; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_dashboard_riesgo_fecha_semaforo ON siarc.tb_resultado_riesgo USING btree (fecha_evaluacion, semaforo);


--
-- Name: idx_garantia_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_garantia_credito ON siarc.tb_garantia USING btree (id_credito);


--
-- Name: idx_gestion_cobranza_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_gestion_cobranza_credito ON siarc.tb_gestion_cobranza USING btree (id_credito_originado);


--
-- Name: idx_gestion_cobranza_fecha; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_gestion_cobranza_fecha ON siarc.tb_gestion_cobranza USING btree (fecha_gestion);


--
-- Name: idx_gestion_cobranza_resultado; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_gestion_cobranza_resultado ON siarc.tb_gestion_cobranza USING btree (resultado_gestion);


--
-- Name: idx_mifos_credito_atraso; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_mifos_credito_atraso ON siarc.tb_mifos_credito USING btree (days_in_arrears);


--
-- Name: idx_mifos_credito_cliente; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_mifos_credito_cliente ON siarc.tb_mifos_credito USING btree (id_mifos_cliente);


--
-- Name: idx_mv_dataset_ia_pd_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE UNIQUE INDEX idx_mv_dataset_ia_pd_credito ON siarc.mv_dataset_ia_pd USING btree (id_credito);


--
-- Name: idx_mv_riesgo_cartera_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE UNIQUE INDEX idx_mv_riesgo_cartera_credito ON siarc.mv_riesgo_cartera USING btree (id_credito);


--
-- Name: idx_mv_riesgo_cartera_estado; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_mv_riesgo_cartera_estado ON siarc.mv_riesgo_cartera USING btree (estado);


--
-- Name: idx_mv_riesgo_cartera_etapa; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_mv_riesgo_cartera_etapa ON siarc.mv_riesgo_cartera USING btree (etapa_riesgo_siarc);


--
-- Name: idx_mv_riesgo_cartera_producto; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_mv_riesgo_cartera_producto ON siarc.mv_riesgo_cartera USING btree (nombre_producto);


--
-- Name: idx_mv_riesgo_cartera_semaforo; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_mv_riesgo_cartera_semaforo ON siarc.mv_riesgo_cartera USING btree (semaforo);


--
-- Name: idx_pago_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_pago_credito ON siarc.tb_pago USING btree (id_credito);


--
-- Name: idx_pago_fecha; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_pago_fecha ON siarc.tb_pago USING btree (fecha_pago);


--
-- Name: idx_pago_mifos_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_pago_mifos_credito ON siarc.tb_mifos_pago USING btree (id_mifos_credito);


--
-- Name: idx_perdida_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_perdida_credito ON siarc.tb_perdida_esperada USING btree (id_credito);


--
-- Name: idx_perdida_fecha; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_perdida_fecha ON siarc.tb_perdida_esperada USING btree (fecha_calculo);


--
-- Name: idx_poliza_detalle_cuenta; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_poliza_detalle_cuenta ON siarc.tb_poliza_detalle USING btree (cuenta);


--
-- Name: idx_poliza_detalle_poliza; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_poliza_detalle_poliza ON siarc.tb_poliza_detalle USING btree (id_poliza);


--
-- Name: idx_poliza_evento; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_poliza_evento ON siarc.tb_poliza_contable USING btree (clave_evento);


--
-- Name: idx_poliza_referencia; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_poliza_referencia ON siarc.tb_poliza_contable USING btree (referencia);


--
-- Name: idx_resultado_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_resultado_credito ON siarc.tb_resultado_riesgo USING btree (id_credito);


--
-- Name: idx_resultado_fecha; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_resultado_fecha ON siarc.tb_resultado_riesgo USING btree (fecha_evaluacion);


--
-- Name: idx_resultado_ia_pd_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_resultado_ia_pd_credito ON siarc.tb_resultado_ia_pd USING btree (id_credito);


--
-- Name: idx_resultado_modelo; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_resultado_modelo ON siarc.tb_resultado_riesgo USING btree (id_modelo);


--
-- Name: idx_solicitud_curp; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_solicitud_curp ON siarc.tb_solicitud_credito USING btree (curp);


--
-- Name: idx_solicitud_estatus; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_solicitud_estatus ON siarc.tb_solicitud_credito USING btree (estatus);


--
-- Name: idx_solicitud_fecha; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_solicitud_fecha ON siarc.tb_solicitud_credito USING btree (fecha_solicitud);


--
-- Name: idx_solicitud_folio; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_solicitud_folio ON siarc.tb_solicitud_credito USING btree (folio_solicitud);


--
-- Name: idx_tb_alerta_temprana_atendida; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_alerta_temprana_atendida ON siarc.tb_alerta_temprana USING btree (atendida);


--
-- Name: idx_tb_alerta_temprana_fecha; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_alerta_temprana_fecha ON siarc.tb_alerta_temprana USING btree (fecha_alerta);


--
-- Name: idx_tb_clasificacion_cartera_etapa; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_clasificacion_cartera_etapa ON siarc.tb_clasificacion_cartera USING btree (etapa_riesgo);


--
-- Name: idx_tb_clasificacion_cartera_grado; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_clasificacion_cartera_grado ON siarc.tb_clasificacion_cartera USING btree (grado_riesgo);


--
-- Name: idx_tb_cliente_estado_municipio; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_cliente_estado_municipio ON siarc.tb_cliente USING btree (estado, municipio);


--
-- Name: idx_tb_cliente_nombre; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_cliente_nombre ON siarc.tb_cliente USING btree (nombre_cliente);


--
-- Name: idx_tb_credito_castigado; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_credito_castigado ON siarc.tb_credito USING btree (castigado);


--
-- Name: idx_tb_credito_fecha_otorgamiento; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_credito_fecha_otorgamiento ON siarc.tb_credito USING btree (fecha_otorgamiento);


--
-- Name: idx_tb_credito_fecha_vencimiento; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_credito_fecha_vencimiento ON siarc.tb_credito USING btree (fecha_vencimiento);


--
-- Name: idx_tb_credito_producto_sucursal; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_credito_producto_sucursal ON siarc.tb_credito USING btree (id_producto, id_sucursal);


--
-- Name: idx_tb_credito_reestructurado; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_credito_reestructurado ON siarc.tb_credito USING btree (reestructurado);


--
-- Name: idx_tb_credito_saldo_actual; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_credito_saldo_actual ON siarc.tb_credito USING btree (saldo_actual);


--
-- Name: idx_tb_garantia_tipo; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_garantia_tipo ON siarc.tb_garantia USING btree (id_tipo_garantia);


--
-- Name: idx_tb_mifos_cliente_external; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_mifos_cliente_external ON siarc.tb_mifos_cliente USING btree (external_id);


--
-- Name: idx_tb_mifos_cliente_office; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_mifos_cliente_office ON siarc.tb_mifos_cliente USING btree (office_id);


--
-- Name: idx_tb_mifos_credito_account; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_mifos_credito_account ON siarc.tb_mifos_credito USING btree (account_no);


--
-- Name: idx_tb_mifos_credito_balance; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_mifos_credito_balance ON siarc.tb_mifos_credito USING btree (outstanding_balance);


--
-- Name: idx_tb_mifos_credito_status; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_mifos_credito_status ON siarc.tb_mifos_credito USING btree (loan_status);


--
-- Name: idx_tb_mifos_pago_transaction; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_mifos_pago_transaction ON siarc.tb_mifos_pago USING btree (transaction_id);


--
-- Name: idx_tb_pago_fecha_credito; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_pago_fecha_credito ON siarc.tb_pago USING btree (fecha_pago, id_credito);


--
-- Name: idx_tb_perdida_esperada_escenario; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_perdida_esperada_escenario ON siarc.tb_perdida_esperada USING btree (escenario);


--
-- Name: idx_tb_resultado_riesgo_clasificacion; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_resultado_riesgo_clasificacion ON siarc.tb_resultado_riesgo USING btree (clasificacion_riesgo);


--
-- Name: idx_tb_resultado_riesgo_pd; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_resultado_riesgo_pd ON siarc.tb_resultado_riesgo USING btree (probabilidad_incumplimiento);


--
-- Name: idx_tb_resultado_riesgo_score; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_resultado_riesgo_score ON siarc.tb_resultado_riesgo USING btree (score_riesgo);


--
-- Name: idx_tb_resultado_riesgo_semaforo; Type: INDEX; Schema: siarc; Owner: -
--

CREATE INDEX idx_tb_resultado_riesgo_semaforo ON siarc.tb_resultado_riesgo USING btree (semaforo);


--
-- Name: tb_cliente trg_cliente_actualizacion; Type: TRIGGER; Schema: siarc; Owner: -
--

CREATE TRIGGER trg_cliente_actualizacion BEFORE UPDATE ON siarc.tb_cliente FOR EACH ROW EXECUTE FUNCTION siarc.fn_actualizar_fecha_actualizacion();


--
-- Name: tb_credito trg_credito_actualizacion; Type: TRIGGER; Schema: siarc; Owner: -
--

CREATE TRIGGER trg_credito_actualizacion BEFORE UPDATE ON siarc.tb_credito FOR EACH ROW EXECUTE FUNCTION siarc.fn_actualizar_fecha_actualizacion();


--
-- Name: tb_garantia trg_garantia_actualizacion; Type: TRIGGER; Schema: siarc; Owner: -
--

CREATE TRIGGER trg_garantia_actualizacion BEFORE UPDATE ON siarc.tb_garantia FOR EACH ROW EXECUTE FUNCTION siarc.fn_actualizar_fecha_actualizacion();


--
-- Name: tb_alerta_temprana tb_alerta_temprana_id_credito_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_alerta_temprana
    ADD CONSTRAINT tb_alerta_temprana_id_credito_fkey FOREIGN KEY (id_credito) REFERENCES siarc.tb_credito(id_credito);


--
-- Name: tb_alerta_temprana tb_alerta_temprana_id_resultado_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_alerta_temprana
    ADD CONSTRAINT tb_alerta_temprana_id_resultado_fkey FOREIGN KEY (id_resultado) REFERENCES siarc.tb_resultado_riesgo(id_resultado);


--
-- Name: tb_analisis_credito tb_analisis_credito_id_solicitud_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_analisis_credito
    ADD CONSTRAINT tb_analisis_credito_id_solicitud_fkey FOREIGN KEY (id_solicitud) REFERENCES siarc.tb_solicitud_credito(id_solicitud);


--
-- Name: tb_clasificacion_cartera tb_clasificacion_cartera_id_credito_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_clasificacion_cartera
    ADD CONSTRAINT tb_clasificacion_cartera_id_credito_fkey FOREIGN KEY (id_credito) REFERENCES siarc.tb_credito(id_credito);


--
-- Name: tb_clasificacion_cartera tb_clasificacion_cartera_id_resultado_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_clasificacion_cartera
    ADD CONSTRAINT tb_clasificacion_cartera_id_resultado_fkey FOREIGN KEY (id_resultado) REFERENCES siarc.tb_resultado_riesgo(id_resultado);


--
-- Name: tb_comite_credito tb_comite_credito_decision_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_comite_credito
    ADD CONSTRAINT tb_comite_credito_decision_fkey FOREIGN KEY (decision) REFERENCES siarc.cat_decision_comite(clave);


--
-- Name: tb_comite_credito tb_comite_credito_id_solicitud_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_comite_credito
    ADD CONSTRAINT tb_comite_credito_id_solicitud_fkey FOREIGN KEY (id_solicitud) REFERENCES siarc.tb_solicitud_credito(id_solicitud);


--
-- Name: tb_credito_calendario tb_credito_calendario_id_credito_originado_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_calendario
    ADD CONSTRAINT tb_credito_calendario_id_credito_originado_fkey FOREIGN KEY (id_credito_originado) REFERENCES siarc.tb_credito_originado(id_credito_originado);


--
-- Name: tb_credito_cobertura_garantia tb_credito_cobertura_garantia_id_credito_originado_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_cobertura_garantia
    ADD CONSTRAINT tb_credito_cobertura_garantia_id_credito_originado_fkey FOREIGN KEY (id_credito_originado) REFERENCES siarc.tb_credito_originado(id_credito_originado);


--
-- Name: tb_credito_cobertura_garantia tb_credito_cobertura_garantia_id_fondo_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_cobertura_garantia
    ADD CONSTRAINT tb_credito_cobertura_garantia_id_fondo_fkey FOREIGN KEY (id_fondo) REFERENCES siarc.cat_fondo_garantia(id_fondo);


--
-- Name: tb_credito tb_credito_id_cliente_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito
    ADD CONSTRAINT tb_credito_id_cliente_fkey FOREIGN KEY (id_cliente) REFERENCES siarc.tb_cliente(id_cliente);


--
-- Name: tb_credito tb_credito_id_estado_credito_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito
    ADD CONSTRAINT tb_credito_id_estado_credito_fkey FOREIGN KEY (id_estado_credito) REFERENCES siarc.cat_estado_credito(id_estado_credito);


--
-- Name: tb_credito tb_credito_id_frecuencia_pago_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito
    ADD CONSTRAINT tb_credito_id_frecuencia_pago_fkey FOREIGN KEY (id_frecuencia_pago) REFERENCES siarc.cat_frecuencia_pago(id_frecuencia_pago);


--
-- Name: tb_credito tb_credito_id_producto_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito
    ADD CONSTRAINT tb_credito_id_producto_fkey FOREIGN KEY (id_producto) REFERENCES siarc.cat_producto(id_producto);


--
-- Name: tb_credito tb_credito_id_sucursal_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito
    ADD CONSTRAINT tb_credito_id_sucursal_fkey FOREIGN KEY (id_sucursal) REFERENCES siarc.cat_sucursal(id_sucursal);


--
-- Name: tb_credito_mitigante_riesgo tb_credito_mitigante_riesgo_id_credito_originado_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_mitigante_riesgo
    ADD CONSTRAINT tb_credito_mitigante_riesgo_id_credito_originado_fkey FOREIGN KEY (id_credito_originado) REFERENCES siarc.tb_credito_originado(id_credito_originado);


--
-- Name: tb_credito_mitigante_riesgo tb_credito_mitigante_riesgo_id_mitigante_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_mitigante_riesgo
    ADD CONSTRAINT tb_credito_mitigante_riesgo_id_mitigante_fkey FOREIGN KEY (id_mitigante) REFERENCES siarc.cat_mitigante_riesgo_agro(id_mitigante);


--
-- Name: tb_credito_originado tb_credito_originado_id_solicitud_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_originado
    ADD CONSTRAINT tb_credito_originado_id_solicitud_fkey FOREIGN KEY (id_solicitud) REFERENCES siarc.tb_solicitud_credito(id_solicitud);


--
-- Name: tb_credito_pago tb_credito_pago_id_calendario_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_pago
    ADD CONSTRAINT tb_credito_pago_id_calendario_fkey FOREIGN KEY (id_calendario) REFERENCES siarc.tb_credito_calendario(id_calendario);


--
-- Name: tb_credito_pago tb_credito_pago_id_credito_originado_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_credito_pago
    ADD CONSTRAINT tb_credito_pago_id_credito_originado_fkey FOREIGN KEY (id_credito_originado) REFERENCES siarc.tb_credito_originado(id_credito_originado);


--
-- Name: tb_garantia tb_garantia_id_credito_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_garantia
    ADD CONSTRAINT tb_garantia_id_credito_fkey FOREIGN KEY (id_credito) REFERENCES siarc.tb_credito(id_credito);


--
-- Name: tb_garantia tb_garantia_id_tipo_garantia_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_garantia
    ADD CONSTRAINT tb_garantia_id_tipo_garantia_fkey FOREIGN KEY (id_tipo_garantia) REFERENCES siarc.cat_tipo_garantia(id_tipo_garantia);


--
-- Name: tb_gestion_cobranza tb_gestion_cobranza_id_credito_originado_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_gestion_cobranza
    ADD CONSTRAINT tb_gestion_cobranza_id_credito_originado_fkey FOREIGN KEY (id_credito_originado) REFERENCES siarc.tb_credito_originado(id_credito_originado);


--
-- Name: tb_gestion_cobranza tb_gestion_cobranza_resultado_gestion_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_gestion_cobranza
    ADD CONSTRAINT tb_gestion_cobranza_resultado_gestion_fkey FOREIGN KEY (resultado_gestion) REFERENCES siarc.cat_resultado_gestion_cobranza(clave);


--
-- Name: tb_gestion_cobranza tb_gestion_cobranza_tipo_gestion_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_gestion_cobranza
    ADD CONSTRAINT tb_gestion_cobranza_tipo_gestion_fkey FOREIGN KEY (tipo_gestion) REFERENCES siarc.cat_tipo_gestion_cobranza(clave);


--
-- Name: tb_matriz_transicion tb_matriz_transicion_id_modelo_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_matriz_transicion
    ADD CONSTRAINT tb_matriz_transicion_id_modelo_fkey FOREIGN KEY (id_modelo) REFERENCES siarc.tb_modelo_riesgo(id_modelo);


--
-- Name: tb_modelo_variable tb_modelo_variable_id_modelo_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_modelo_variable
    ADD CONSTRAINT tb_modelo_variable_id_modelo_fkey FOREIGN KEY (id_modelo) REFERENCES siarc.tb_modelo_riesgo(id_modelo);


--
-- Name: tb_modelo_variable tb_modelo_variable_id_variable_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_modelo_variable
    ADD CONSTRAINT tb_modelo_variable_id_variable_fkey FOREIGN KEY (id_variable) REFERENCES siarc.tb_variable_riesgo(id_variable);


--
-- Name: tb_monte_carlo tb_monte_carlo_id_modelo_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_monte_carlo
    ADD CONSTRAINT tb_monte_carlo_id_modelo_fkey FOREIGN KEY (id_modelo) REFERENCES siarc.tb_modelo_riesgo(id_modelo);


--
-- Name: tb_montecarlo_escenario tb_montecarlo_escenario_id_simulacion_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_montecarlo_escenario
    ADD CONSTRAINT tb_montecarlo_escenario_id_simulacion_fkey FOREIGN KEY (id_simulacion) REFERENCES siarc.tb_montecarlo_cartera(id_simulacion);


--
-- Name: tb_montecarlo_ia_escenario tb_montecarlo_ia_escenario_id_simulacion_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_montecarlo_ia_escenario
    ADD CONSTRAINT tb_montecarlo_ia_escenario_id_simulacion_fkey FOREIGN KEY (id_simulacion) REFERENCES siarc.tb_montecarlo_ia_cartera(id_simulacion);


--
-- Name: tb_pago_garantia_fondo tb_pago_garantia_fondo_id_reclamacion_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_pago_garantia_fondo
    ADD CONSTRAINT tb_pago_garantia_fondo_id_reclamacion_fkey FOREIGN KEY (id_reclamacion) REFERENCES siarc.tb_reclamacion_garantia(id_reclamacion);


--
-- Name: tb_pago tb_pago_id_credito_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_pago
    ADD CONSTRAINT tb_pago_id_credito_fkey FOREIGN KEY (id_credito) REFERENCES siarc.tb_credito(id_credito);


--
-- Name: tb_perdida_esperada tb_perdida_esperada_id_credito_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_perdida_esperada
    ADD CONSTRAINT tb_perdida_esperada_id_credito_fkey FOREIGN KEY (id_credito) REFERENCES siarc.tb_credito(id_credito);


--
-- Name: tb_perdida_esperada tb_perdida_esperada_id_resultado_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_perdida_esperada
    ADD CONSTRAINT tb_perdida_esperada_id_resultado_fkey FOREIGN KEY (id_resultado) REFERENCES siarc.tb_resultado_riesgo(id_resultado);


--
-- Name: tb_poliza_contable tb_poliza_contable_clave_evento_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_poliza_contable
    ADD CONSTRAINT tb_poliza_contable_clave_evento_fkey FOREIGN KEY (clave_evento) REFERENCES siarc.cat_evento_contable(clave);


--
-- Name: tb_poliza_detalle tb_poliza_detalle_cuenta_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_poliza_detalle
    ADD CONSTRAINT tb_poliza_detalle_cuenta_fkey FOREIGN KEY (cuenta) REFERENCES siarc.cat_cuenta_contable(cuenta);


--
-- Name: tb_poliza_detalle tb_poliza_detalle_id_poliza_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_poliza_detalle
    ADD CONSTRAINT tb_poliza_detalle_id_poliza_fkey FOREIGN KEY (id_poliza) REFERENCES siarc.tb_poliza_contable(id_poliza);


--
-- Name: tb_reclamacion_garantia tb_reclamacion_garantia_id_cobertura_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_reclamacion_garantia
    ADD CONSTRAINT tb_reclamacion_garantia_id_cobertura_fkey FOREIGN KEY (id_cobertura) REFERENCES siarc.tb_credito_cobertura_garantia(id_cobertura);


--
-- Name: tb_recuperacion_post_garantia tb_recuperacion_post_garantia_id_reclamacion_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_recuperacion_post_garantia
    ADD CONSTRAINT tb_recuperacion_post_garantia_id_reclamacion_fkey FOREIGN KEY (id_reclamacion) REFERENCES siarc.tb_reclamacion_garantia(id_reclamacion);


--
-- Name: tb_resultado_ia_pd tb_resultado_ia_pd_id_credito_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_ia_pd
    ADD CONSTRAINT tb_resultado_ia_pd_id_credito_fkey FOREIGN KEY (id_credito) REFERENCES siarc.tb_credito(id_credito);


--
-- Name: tb_resultado_riesgo tb_resultado_riesgo_id_credito_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_riesgo
    ADD CONSTRAINT tb_resultado_riesgo_id_credito_fkey FOREIGN KEY (id_credito) REFERENCES siarc.tb_credito(id_credito);


--
-- Name: tb_resultado_riesgo tb_resultado_riesgo_id_modelo_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_riesgo
    ADD CONSTRAINT tb_resultado_riesgo_id_modelo_fkey FOREIGN KEY (id_modelo) REFERENCES siarc.tb_modelo_riesgo(id_modelo);


--
-- Name: tb_resultado_variable tb_resultado_variable_id_resultado_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_variable
    ADD CONSTRAINT tb_resultado_variable_id_resultado_fkey FOREIGN KEY (id_resultado) REFERENCES siarc.tb_resultado_riesgo(id_resultado);


--
-- Name: tb_resultado_variable tb_resultado_variable_id_variable_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_resultado_variable
    ADD CONSTRAINT tb_resultado_variable_id_variable_fkey FOREIGN KEY (id_variable) REFERENCES siarc.tb_variable_riesgo(id_variable);


--
-- Name: tb_solicitud_credito tb_solicitud_credito_clave_actividad_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_credito
    ADD CONSTRAINT tb_solicitud_credito_clave_actividad_fkey FOREIGN KEY (clave_actividad) REFERENCES siarc.cat_actividad_economica(clave);


--
-- Name: tb_solicitud_credito tb_solicitud_credito_clave_destino_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_credito
    ADD CONSTRAINT tb_solicitud_credito_clave_destino_fkey FOREIGN KEY (clave_destino) REFERENCES siarc.cat_destino_credito(clave);


--
-- Name: tb_solicitud_credito tb_solicitud_credito_clave_producto_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_credito
    ADD CONSTRAINT tb_solicitud_credito_clave_producto_fkey FOREIGN KEY (clave_producto) REFERENCES siarc.cat_producto_credito(clave);


--
-- Name: tb_solicitud_credito tb_solicitud_credito_clave_tipo_garantia_credito_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_credito
    ADD CONSTRAINT tb_solicitud_credito_clave_tipo_garantia_credito_fkey FOREIGN KEY (clave_tipo_garantia) REFERENCES siarc.cat_tipo_garantia_credito(clave);


--
-- Name: tb_solicitud_credito tb_solicitud_credito_estatus_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_credito
    ADD CONSTRAINT tb_solicitud_credito_estatus_fkey FOREIGN KEY (estatus) REFERENCES siarc.cat_estatus_solicitud(clave);


--
-- Name: tb_solicitud_historial tb_solicitud_historial_id_solicitud_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_solicitud_historial
    ADD CONSTRAINT tb_solicitud_historial_id_solicitud_fkey FOREIGN KEY (id_solicitud) REFERENCES siarc.tb_solicitud_credito(id_solicitud);


--
-- Name: tb_stress_test tb_stress_test_id_modelo_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_stress_test
    ADD CONSTRAINT tb_stress_test_id_modelo_fkey FOREIGN KEY (id_modelo) REFERENCES siarc.tb_modelo_riesgo(id_modelo);


--
-- Name: tb_usuario tb_usuario_rol_fkey; Type: FK CONSTRAINT; Schema: siarc; Owner: -
--

ALTER TABLE ONLY siarc.tb_usuario
    ADD CONSTRAINT tb_usuario_rol_fkey FOREIGN KEY (rol) REFERENCES siarc.cat_rol_usuario(rol);


--
-- PostgreSQL database dump complete
--

\unrestrict tMQcuAYipWCDpvXAvNgk4ymRUxPDA17L7wZeZ8YZLK9nd0aljMQtwtulsE7DfCr

