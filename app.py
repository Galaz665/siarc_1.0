##export DATABASE_URL="postgresql+psycopg2://usuario:password@localhost:5432/siarc"
#export SIARC_SECRET_KEY="una_clave_larga_y_segura"
#uvicorn app:app --host 0.0.0.0 --port 8001 --reload


from datetime import datetime
from fastapi import FastAPI, Request
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from jinja2 import Environment, FileSystemLoader
from fastapi import Form
from sqlalchemy import text
from db import engine
from fastapi.responses import RedirectResponse
from db import fetch_one, fetch_all
import csv
import io
from starlette.middleware.sessions import SessionMiddleware
import hashlib
import base64
from fastapi.responses import RedirectResponse, StreamingResponse
import os

app = FastAPI(
    title="SIARC Web",
    description="Interfaz Operativa SIARC 1.0",
    version="1.0.0"
)

SIARC_SECRET_KEY = os.getenv("SIARC_SECRET_KEY", "dev-secret-key-cambiar")
app.add_middleware(
    SessionMiddleware,
    secret_key=SIARC_SECRET_KEY
)

templates = Jinja2Templates(directory="templates")
templates.env = Environment(
    loader=FileSystemLoader("templates"),
    cache_size=0,
    auto_reload=True
)

app.mount("/static", StaticFiles(directory="static"), name="static")

def verificar_password(password: str, password_hash: str) -> bool:
    try:
        algoritmo, iteraciones, salt_b64, hash_b64 = password_hash.split("$")

        if algoritmo != "pbkdf2_sha256":
            return False

        salt = base64.b64decode(salt_b64)
        hash_guardado = base64.b64decode(hash_b64)

        hash_calculado = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode(),
            salt,
            int(iteraciones)
        )

        return hash_calculado == hash_guardado

    except Exception:
        return False
@app.get("/login")
def login_form(request: Request):
    return templates.TemplateResponse(
        request,
        "login.html",
        {"error": None}
    )


@app.post("/login")
def login_post(
    request: Request,
    usuario: str = Form(...),
    password: str = Form(...)
):
    user = fetch_one("""
        SELECT
            id_usuario,
            usuario,
            password_hash,
            nombre,
            rol,
            activo
        FROM siarc.tb_usuario
        WHERE usuario = :usuario
    """, {"usuario": usuario})

    if not user:
        return templates.TemplateResponse(
            request,
            "login.html",
            {"error": "Usuario o contraseña incorrectos"}
        )

    if not user["activo"]:
        return templates.TemplateResponse(
            request,
            "login.html",
            {"error": "Usuario inactivo"}
        )

    if not verificar_password(password, user["password_hash"]):
        return templates.TemplateResponse(
            request,
            "login.html",
            {"error": "Usuario o contraseña incorrectos"}
        )

    request.session["usuario"] = user["usuario"]
    request.session["nombre"] = user["nombre"]
    request.session["rol"] = user["rol"]

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_registrar_log_acceso(
                :usuario,
                :rol,
                :ip,
                'LOGIN',
                'Inicio de sesión'
        )
    """), {
        "usuario": user["usuario"],
        "rol": user["rol"],
        "ip": request.client.host
    })

    return RedirectResponse("/", status_code=303)

def requiere_login(request: Request):
    if "usuario" not in request.session:
        return RedirectResponse("/login", status_code=303)
    return None

def requiere_rol(request: Request, roles_permitidos: list):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    rol = request.session.get("rol")

    if rol not in roles_permitidos:
        return RedirectResponse("/", status_code=303)

    return None

@app.get("/logout")
def logout(request: Request):

    usuario = request.session.get("usuario")
    rol = request.session.get("rol")

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_registrar_log_acceso(
                :usuario,
                :rol,
                :ip,
                'LOGOUT',
                'Cierre de sesión'
            )
        """), {
            "usuario": usuario,
            "rol": rol,
            "ip": request.client.host
        })

    request.session.clear()

    return RedirectResponse(
        "/login",
        status_code=303
    )


@app.get("/")
def dashboard(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect
    resumen = fetch_one("""
        SELECT *
        FROM siarc.vw_dashboard_ejecutivo
    """)

    alertas = fetch_all("""
        SELECT *
        FROM siarc.vw_dashboard_alertas
        ORDER BY dias_atraso DESC
    """)

    return templates.TemplateResponse(
        request,
        "dashboard.html",
        {
            "resumen": resumen,
            "alertas": alertas
        }
    )


@app.get("/solicitudes")
def solicitudes(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect
    datos = fetch_all("""
        SELECT
            s.id_solicitud,
            s.folio_solicitud,
            s.nombre || ' ' || COALESCE(s.paterno, '') || ' ' || COALESCE(s.materno, '') AS solicitante,
            s.estado,
            s.municipio,
            s.monto_solicitado,
            s.plazo_meses,
            s.estatus,
            s.score_preliminar,
            s.semaforo_preliminar,
            s.monto_recomendado,
            s.dictamen_preliminar,
            CASE
                WHEN c.id_credito_originado IS NULL THEN FALSE
                ELSE TRUE
            END AS tiene_credito
        FROM siarc.tb_solicitud_credito s
        LEFT JOIN siarc.tb_credito_originado c
            ON s.id_solicitud = c.id_solicitud
        ORDER BY s.id_solicitud;
    """)

    return templates.TemplateResponse(
        request,
        "solicitudes.html",
        {"datos": datos}
    )
@app.get("/solicitudes/nueva")
def nueva_solicitud(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    return templates.TemplateResponse(
        request,
        "nueva_solicitud.html",
        {}
    )

@app.get("/creditos")
def creditos(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect
    datos = fetch_all("""
        SELECT
            codigo_credito,
            nombre_acreditado,
            monto_aprobado,
            saldo_actual,
            monto_vencido,
            dias_atraso,
            etapa_riesgo,
            clasificacion_cartera
        FROM siarc.vw_cartera_crediticia
        ORDER BY codigo_credito
    """)

    return templates.TemplateResponse(
        request,
        "creditos.html",
        {"datos": datos}
    )


@app.get("/riesgo")
def riesgo(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect
    datos = fetch_all("""
        SELECT
            codigo_credito,
            nombre_acreditado,
            saldo_actual,
            dias_atraso,
            pd,
            lgd,
            ead,
            perdida_esperada,
            semaforo,
            estatus_gestion_riesgo
        FROM siarc.vw_riesgo_creditos_vivos
        ORDER BY dias_atraso DESC
    """)

    return templates.TemplateResponse(
        request,
        "riesgo.html",
        {"datos": datos}
    )


@app.get("/fonaga")
def fonaga(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect
    datos = fetch_all("""
        SELECT *
        FROM siarc.vw_reclamaciones_garantia
        ORDER BY id_reclamacion DESC
    """)

    return templates.TemplateResponse(
        request,
        "fonaga.html",
        {"datos": datos}
    )
    
@app.get("/reservas")
def reservas(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    datos = fetch_all("""
        SELECT *
        FROM siarc.vw_reporte_reservas_ifrs9
        ORDER BY codigo_credito
    """)

    return templates.TemplateResponse(
        request,
        "reservas.html",
        {"datos": datos}
    )


@app.get("/contabilidad")
def contabilidad(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    resumen = fetch_all("""
        SELECT *
        FROM siarc.vw_resumen_contable
        ORDER BY cuenta
    """)

    polizas = fetch_all("""
        SELECT *
        FROM siarc.vw_polizas_balance
        ORDER BY id_poliza DESC
    """)

    return templates.TemplateResponse(
        request,
        "contabilidad.html",
        {
            "resumen": resumen,
            "polizas": polizas
        }
    )


@app.get("/auditoria")
def auditoria(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    datos = fetch_all("""
        SELECT *
        FROM siarc.vw_bitacora_reciente
        LIMIT 200
    """)

    return templates.TemplateResponse(
        request,
        "auditoria.html",
        {"datos": datos}
    )
    
    
@app.post("/solicitudes/nueva")
def guardar_solicitud(
    request: Request,

    nombre: str = Form(...),
    paterno: str = Form(""),
    materno: str = Form(""),
    curp: str = Form(""),
    rfc: str = Form(""),
    telefono: str = Form(""),
    correo: str = Form(""),

    estado: str = Form(""),
    municipio: str = Form(""),
    localidad: str = Form(""),
    domicilio: str = Form(""),

    actividad_economica: str = Form(""),
    ingresos_mensuales: float = Form(0),
    egresos_mensuales: float = Form(0),

    producto_solicitado: str = Form(""),
    destino_credito: str = Form(""),
    monto_solicitado: float = Form(...),
    plazo_meses: int = Form(...),
    tasa_interes_anual: float = Form(0),

    tipo_garantia: str = Form(""),
    valor_garantia: float = Form(0),

    clave_producto: str = Form(""),
    clave_actividad: str = Form(""),
    clave_destino: str = Form(""),
    clave_tipo_garantia: str = Form("")
):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    folio = f"SOL-{datetime.now().strftime('%Y%m%d%H%M%S')}"

    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO siarc.tb_solicitud_credito (
                folio_solicitud,
                nombre,
                paterno,
                materno,
                curp,
                rfc,
                telefono,
                correo,
                estado,
                municipio,
                localidad,
                domicilio,
                actividad_economica,
                ingresos_mensuales,
                egresos_mensuales,
                producto_solicitado,
                destino_credito,
                monto_solicitado,
                plazo_meses,
                tasa_interes_anual,
                tipo_garantia,
                valor_garantia,
                estatus,
                clave_producto,
                clave_actividad,
                clave_destino,
                clave_tipo_garantia
            )
            VALUES (
                :folio,
                :nombre,
                :paterno,
                :materno,
                :curp,
                :rfc,
                :telefono,
                :correo,
                :estado,
                :municipio,
                :localidad,
                :domicilio,
                :actividad_economica,
                :ingresos_mensuales,
                :egresos_mensuales,
                :producto_solicitado,
                :destino_credito,
                :monto_solicitado,
                :plazo_meses,
                :tasa_interes_anual,
                :tipo_garantia,
                :valor_garantia,
                'CAPTURADA',
                :clave_producto,
                :clave_actividad,
                :clave_destino,
                :clave_tipo_garantia
            )
        """), {
            "folio": folio,
            "nombre": nombre,
            "paterno": paterno,
            "materno": materno,
            "curp": curp,
            "rfc": rfc,
            "telefono": telefono,
            "correo": correo,
            "estado": estado,
            "municipio": municipio,
            "localidad": localidad,
            "domicilio": domicilio,
            "actividad_economica": actividad_economica,
            "ingresos_mensuales": ingresos_mensuales,
            "egresos_mensuales": egresos_mensuales,
            "producto_solicitado": producto_solicitado,
            "destino_credito": destino_credito,
            "monto_solicitado": monto_solicitado,
            "plazo_meses": plazo_meses,
            "tasa_interes_anual": tasa_interes_anual,
            "tipo_garantia": tipo_garantia,
            "valor_garantia": valor_garantia,
            "clave_producto": clave_producto,
            "clave_actividad": clave_actividad,
            "clave_destino": clave_destino,
            "clave_tipo_garantia": clave_tipo_garantia
        })

    return RedirectResponse(
        url="/solicitudes",
        status_code=303
    )

@app.get("/solicitudes/{id_solicitud}/analizar")
def analizar_solicitud(request: Request, id_solicitud: int):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    solicitud = fetch_one("""
        SELECT *
        FROM siarc.tb_solicitud_credito
        WHERE id_solicitud = :id
    """, {"id": id_solicitud})

    ingresos = float(solicitud["ingresos_mensuales"] or 0)
    egresos = float(solicitud["egresos_mensuales"] or 0)

    capacidad = ingresos - egresos

    # Score básico inicial
    if capacidad >= 15000:
        score = 95
        semaforo = "VERDE"
        dictamen = "APROBADO"
        factor = 1.20

    elif capacidad >= 5000:
        score = 75
        semaforo = "AMARILLO"
        dictamen = "APROBADO CON OBSERVACIONES"
        factor = 1.00

    else:
        score = 40
        semaforo = "ROJO"
        dictamen = "RECHAZADO"
        factor = 0.50

    monto_recomendado = (
        float(solicitud["monto_solicitado"]) * factor
    )

    with engine.begin() as conn:

        conn.execute(text("""
            UPDATE siarc.tb_solicitud_credito
            SET
                score_preliminar = :score,
                semaforo_preliminar = :semaforo,
                monto_recomendado = :monto,
                dictamen_preliminar = :dictamen,
                estatus = 'ANALISIS',
                fecha_actualizacion = now()
            WHERE id_solicitud = :id
        """), {
            "score": score,
            "semaforo": semaforo,
            "monto": monto_recomendado,
            "dictamen": dictamen,
            "id": id_solicitud
        })

    return RedirectResponse(
        "/solicitudes",
        status_code=303
    )
    
@app.get("/solicitudes/{id_solicitud}/comite")
def enviar_comite(request: Request, id_solicitud: int):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_enviar_solicitud_comite(
                :id,
                'SIARC_WEB'
            )
        """), {"id": id_solicitud})

    return RedirectResponse("/solicitudes", status_code=303)


@app.get("/solicitudes/{id_solicitud}/aprobar")
def aprobar_solicitud(request: Request, id_solicitud: int):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    solicitud = fetch_one("""
        SELECT *
        FROM siarc.tb_solicitud_credito
        WHERE id_solicitud = :id
    """, {"id": id_solicitud})

    monto = solicitud["monto_recomendado"] or solicitud["monto_solicitado"]
    plazo = solicitud["plazo_meses"]
    tasa = solicitud["tasa_interes_anual"] or 0.28

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_resolver_comite_credito(
                :id,
                'APROBADO',
                :monto,
                :plazo,
                :tasa,
                'Aprobado desde SIARC Web',
                'Resolución automática demo',
                'COMITE_WEB'
            )
        """), {
            "id": id_solicitud,
            "monto": monto,
            "plazo": plazo,
            "tasa": tasa
        })

    return RedirectResponse("/solicitudes", status_code=303)


@app.get("/solicitudes/{id_solicitud}/rechazar")
def rechazar_solicitud(request: Request, id_solicitud: int):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    solicitud = fetch_one("""
        SELECT *
        FROM siarc.tb_solicitud_credito
        WHERE id_solicitud = :id
    """, {"id": id_solicitud})

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_resolver_comite_credito(
                :id,
                'RECHAZADO',
                0,
                :plazo,
                :tasa,
                'Rechazado desde SIARC Web',
                'Resolución automática demo',
                'COMITE_WEB'
            )
        """), {
            "id": id_solicitud,
            "plazo": solicitud["plazo_meses"],
            "tasa": solicitud["tasa_interes_anual"] or 0.28
        })

    return RedirectResponse("/solicitudes", status_code=303)
    
    
@app.get("/solicitudes/{id_solicitud}/originar")
def originar_credito(request: Request, id_solicitud: int):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    existente = fetch_one("""
        SELECT id_credito_originado, codigo_credito
        FROM siarc.tb_credito_originado
        WHERE id_solicitud = :id
        LIMIT 1
    """, {"id": id_solicitud})

    if existente:
        return RedirectResponse("/creditos", status_code=303)

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_formalizar_credito(
                :id,
                'SIARC_WEB'
            )
        """), {"id": id_solicitud})

        conn.execute(text("""
            SELECT siarc.fn_generar_calendario_credito(
                (
                    SELECT id_credito_originado
                    FROM siarc.tb_credito_originado
                    WHERE id_solicitud = :id
                    ORDER BY id_credito_originado DESC
                    LIMIT 1
                ),
                (CURRENT_DATE + INTERVAL '1 month')::DATE
            )
        """), {"id": id_solicitud})

    return RedirectResponse("/creditos", status_code=303)
    
@app.get("/creditos/{codigo_credito}")
def detalle_credito(request: Request, codigo_credito: str):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT
             c.*,
             g.porcentaje_cobertura,
             g.monto_maximo_cubierto,
             g.estatus_cobertura,
             f.nombre as nombre_fondo
        FROM siarc.tb_credito_originado c
        LEFT JOIN siarc.tb_credito_cobertura_garantia g
              ON c.id_credito_originado = g.id_credito_originado
        LEFT JOIN siarc.cat_fondo_garantia f
              ON g.id_fondo = f.id_fondo
        WHERE c.codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    riesgo = fetch_one("""
        SELECT *
        FROM siarc.vw_riesgo_creditos_vivos
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    calendario = fetch_all("""
        SELECT
            cal.numero_pago,
            cal.fecha_vencimiento,
            cal.saldo_inicial,
            cal.capital_programado,
            cal.interes_programado,
            cal.pago_programado,
            cal.saldo_final,
            cal.estatus_pago
        FROM siarc.tb_credito_calendario cal
        JOIN siarc.tb_credito_originado c
            ON cal.id_credito_originado = c.id_credito_originado
        WHERE c.codigo_credito = :codigo
        ORDER BY numero_pago
    """, {"codigo": codigo_credito})

    pagos = fetch_all("""
        SELECT
            p.numero_pago,
            p.fecha_pago,
            p.importe_pagado,
            p.capital_pagado,
            p.interes_pagado,
            p.saldo_anterior,
            p.saldo_posterior,
            p.usuario
        FROM siarc.tb_credito_pago p
        JOIN siarc.tb_credito_originado c
            ON p.id_credito_originado = c.id_credito_originado
        WHERE c.codigo_credito = :codigo
        ORDER BY p.fecha_pago DESC
    """, {"codigo": codigo_credito})

    reservas = fetch_one("""
        SELECT *
        FROM siarc.vw_reporte_reservas_ifrs9
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    polizas = fetch_all("""
        SELECT *
        FROM siarc.vw_polizas_balance
        WHERE referencia = :codigo
        ORDER BY id_poliza DESC
    """, {"codigo": codigo_credito})
    
    desembolsado = any(
    p["clave_evento"] == "DESEMBOLSO"
    for p in polizas
    )

    reclamacion = fetch_one("""
        SELECT *
        FROM siarc.vw_reclamaciones_garantia
        WHERE codigo_credito = :codigo
        ORDER BY id_reclamacion DESC
        LIMIT 1
    """,  {"codigo": codigo_credito})

    return templates.TemplateResponse(
        request,
        "detalle_credito.html",
        {
            "credito": credito,
            "riesgo": riesgo,
            "calendario": calendario,
            "pagos": pagos,
            "reservas": reservas,
            "polizas": polizas,
            "desembolsado": desembolsado,
            "reclamacion": reclamacion
        }
    )

@app.get("/creditos/{codigo_credito}/desembolsar")
def desembolsar_credito(request: Request, codigo_credito: str):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT
            id_credito_originado,
            codigo_credito,
            estatus_credito
        FROM siarc.tb_credito_originado
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    if not credito:
        return RedirectResponse("/creditos", status_code=303)

    poliza = fetch_one("""
        SELECT id_poliza
        FROM siarc.tb_poliza_contable
        WHERE referencia = :codigo
          AND clave_evento = 'DESEMBOLSO'
        LIMIT 1
    """, {"codigo": codigo_credito})

    if not poliza:
        with engine.begin() as conn:
            conn.execute(text("""
                SELECT siarc.fn_generar_poliza_desembolso(
                    :id_credito
                )
            """), {
                "id_credito": credito["id_credito_originado"]
            })

            conn.execute(text("""
                UPDATE siarc.tb_credito_originado
                SET
                    estatus_credito = 'ACTIVO',
                    fecha_actualizacion = now()
                WHERE id_credito_originado = :id_credito
            """), {
                "id_credito": credito["id_credito_originado"]
            })

    return RedirectResponse(
        f"/creditos/{codigo_credito}",
        status_code=303
    )
    
    
@app.get("/creditos/{codigo_credito}/pago")
def formulario_pago(request: Request, codigo_credito: str):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT
            id_credito_originado,
            codigo_credito,
            nombre_acreditado,
            saldo_actual
        FROM siarc.tb_credito_originado
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    siguiente_pago = fetch_one("""
        SELECT
            cal.numero_pago,
            cal.fecha_vencimiento,
            cal.pago_programado,
            cal.capital_programado,
            cal.interes_programado
        FROM siarc.tb_credito_calendario cal
        JOIN siarc.tb_credito_originado c
            ON cal.id_credito_originado = c.id_credito_originado
        WHERE c.codigo_credito = :codigo
          AND cal.estatus_pago IN ('PENDIENTE', 'PARCIAL')
        ORDER BY cal.numero_pago
        LIMIT 1
    """, {"codigo": codigo_credito})

    return templates.TemplateResponse(
        request,
        "registrar_pago.html",
        {
            "credito": credito,
            "siguiente_pago": siguiente_pago
        }
    )



@app.post("/creditos/{codigo_credito}/pago")
def aplicar_pago_web(
    request: Request,
    codigo_credito: str,
    fecha_pago: str = Form(...),
    importe_pagado: float = Form(...),
    referencia_pago: str = Form(""),
    canal_pago: str = Form("CAJA"),
    observaciones: str = Form(""),
    usuario: str = Form("SIARC_WEB")
):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT id_credito_originado
        FROM siarc.tb_credito_originado
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    if not credito:
        return RedirectResponse("/creditos", status_code=303)

    with engine.begin() as conn:

        conn.execute(text("""
            SELECT siarc.fn_aplicar_pago_credito(
                :id_credito,
                :fecha_pago,
                :importe_pagado,
                :usuario
            )
        """), {
            "id_credito": credito["id_credito_originado"],
            "fecha_pago": fecha_pago,
            "importe_pagado": importe_pagado,
            "usuario": usuario
        })

        id_pago = conn.execute(text("""
            SELECT id_pago
            FROM siarc.tb_credito_pago
            WHERE id_credito_originado = :id_credito
            ORDER BY id_pago DESC
            LIMIT 1
        """), {
            "id_credito": credito["id_credito_originado"]
        }).scalar()

        if id_pago:
            conn.execute(text("""
                UPDATE siarc.tb_credito_pago
                SET
                    referencia_pago = :referencia_pago,
                    canal_pago = :canal_pago,
                    observaciones = :observaciones
                WHERE id_pago = :id_pago
            """), {
                "referencia_pago": referencia_pago,
                "canal_pago": canal_pago,
                "observaciones": observaciones,
                "id_pago": id_pago
            })

            conn.execute(text("""
                SELECT siarc.fn_generar_poliza_pago_credito(:id_pago)
            """), {
                "id_pago": id_pago
            })

    return RedirectResponse(
        f"/creditos/{codigo_credito}",
        status_code=303
    )
    
@app.get("/creditos/{codigo_credito}/liquidar")
def liquidar_credito_web(request: Request, codigo_credito: str):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT id_credito_originado
        FROM siarc.tb_credito_originado
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    if not credito:
        return RedirectResponse("/creditos", status_code=303)

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_liquidar_credito(
                :id_credito,
                CURRENT_DATE,
                :referencia,
                'CAJA',
                'Liquidación total desde SIARC Web',
                'SIARC_WEB'
            )
        """), {
            "id_credito": credito["id_credito_originado"],
            "referencia": f"LIQ-{codigo_credito}"
        })

    return RedirectResponse(
        f"/creditos/{codigo_credito}",
        status_code=303
    )
    
@app.post("/creditos/{codigo_credito}/liquidacion")
def aplicar_liquidacion_web(
    request: Request,
    codigo_credito: str,
    fecha_pago: str = Form(...),
    referencia_pago: str = Form(...),
    canal_pago: str = Form("CAJA"),
    observaciones: str = Form(""),
    usuario: str = Form("SIARC_WEB")
):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT id_credito_originado
        FROM siarc.tb_credito_originado
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    if not credito:
        return RedirectResponse("/creditos", status_code=303)

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_liquidar_credito(
                :id_credito,
                :fecha_pago,
                :referencia_pago,
                :canal_pago,
                :observaciones,
                :usuario
            )
        """), {
            "id_credito": credito["id_credito_originado"],
            "fecha_pago": fecha_pago,
            "referencia_pago": referencia_pago,
            "canal_pago": canal_pago,
            "observaciones": observaciones,
            "usuario": usuario
        })

    return RedirectResponse(
        f"/creditos/{codigo_credito}",
        status_code=303
    )
    
@app.get("/creditos/{codigo_credito}/liquidacion")
def formulario_liquidacion(request: Request, codigo_credito: str):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT
            id_credito_originado,
            codigo_credito,
            nombre_acreditado,
            saldo_actual
        FROM siarc.tb_credito_originado
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    return templates.TemplateResponse(
        request,
        "liquidar_credito.html",
        {"credito": credito}
    )
@app.get("/creditos/{codigo_credito}/garantia")
def formulario_garantia(request: Request, codigo_credito: str):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT
            id_credito_originado,
            codigo_credito,
            nombre_acreditado,
            saldo_actual
        FROM siarc.tb_credito_originado
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    return templates.TemplateResponse(
        request,
        "asignar_garantia.html",
        {"credito": credito}
    )


@app.post("/creditos/{codigo_credito}/garantia")
def asignar_garantia_web(
    request: Request,
    codigo_credito: str,
    fondo: str = Form("FONAGA"),
    porcentaje: float = Form(...),
    observaciones: str = Form("")
):
    redirect = requiere_login(request, ["ADMIN", "ANALISTA"])
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT id_credito_originado
        FROM siarc.tb_credito_originado
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    if not credito:
        return RedirectResponse("/creditos", status_code=303)

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_asignar_cobertura_fondo(
                :id_credito,
                :fondo,
                :porcentaje,
                :observaciones
            )
        """), {
            "id_credito": credito["id_credito_originado"],
            "fondo": fondo,
            "porcentaje": porcentaje,
            "observaciones": observaciones
        })

    return RedirectResponse(
        f"/creditos/{codigo_credito}",
        status_code=303
    )


@app.get("/creditos/{codigo_credito}/reclamar_garantia")
def formulario_reclamar_garantia(request: Request, codigo_credito: str):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT
            id_credito_originado,
            codigo_credito,
            nombre_acreditado,
            saldo_actual
        FROM siarc.tb_credito_originado
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    return templates.TemplateResponse(
        request,
        "reclamar_garantia.html",
        {"credito": credito}
    )


@app.post("/creditos/{codigo_credito}/reclamar_garantia")
def reclamar_garantia_web(
    request: Request,
    codigo_credito: str,
    saldo_reclamado: float = Form(...),
    observaciones: str = Form("")
):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    credito = fetch_one("""
        SELECT id_credito_originado
        FROM siarc.tb_credito_originado
        WHERE codigo_credito = :codigo
    """, {"codigo": codigo_credito})

    if not credito:
        return RedirectResponse("/creditos", status_code=303)

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_reclamar_garantia_fondo(
                :id_credito,
                'FONAGA',
                :saldo_reclamado,
                :observaciones
            )
        """), {
            "id_credito": credito["id_credito_originado"],
            "saldo_reclamado": saldo_reclamado,
            "observaciones": observaciones
        })

    return RedirectResponse(
        f"/creditos/{codigo_credito}",
        status_code=303
    )

@app.get("/fonaga/{id_reclamacion}/pago")
def formulario_pago_fonaga(request: Request, id_reclamacion: int):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    reclamacion = fetch_one("""
        SELECT
            r.id_reclamacion,
            r.codigo_credito,
            r.nombre_acreditado,
            r.fondo,
            r.saldo_reclamado,
            r.monto_reclamado_fondo,
            r.total_pagado_fondo,
            r.estatus_reclamacion
        FROM siarc.vw_reclamaciones_garantia r
        WHERE r.id_reclamacion = :id
    """, {"id": id_reclamacion})

    return templates.TemplateResponse(
        request,
        "pago_fonaga.html",
        {"reclamacion": reclamacion}
    )


@app.post("/fonaga/{id_reclamacion}/pago")
def registrar_pago_fonaga_web(
    request: Request,
    id_reclamacion: int,
    monto_pagado_fondo: float = Form(...),
    referencia_pago: str = Form(...),
    observaciones: str = Form("")
):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    reclamacion = fetch_one("""
        SELECT
            id_reclamacion,
            codigo_credito
        FROM siarc.vw_reclamaciones_garantia
        WHERE id_reclamacion = :id
    """, {"id": id_reclamacion})

    if not reclamacion:
        return RedirectResponse("/fonaga", status_code=303)

    with engine.begin() as conn:
        conn.execute(text("""
            SELECT siarc.fn_registrar_pago_garantia_fondo(
                :id_reclamacion,
                :monto_pagado_fondo,
                :referencia_pago,
                :observaciones
            )
        """), {
            "id_reclamacion": id_reclamacion,
            "monto_pagado_fondo": monto_pagado_fondo,
            "referencia_pago": referencia_pago,
            "observaciones": observaciones
        })

        id_pago_garantia = conn.execute(text("""
            SELECT id_pago_garantia
            FROM siarc.tb_pago_garantia_fondo
            WHERE id_reclamacion = :id_reclamacion
            ORDER BY id_pago_garantia DESC
            LIMIT 1
        """), {
            "id_reclamacion": id_reclamacion
        }).scalar()

        if id_pago_garantia:
            conn.execute(text("""
                SELECT siarc.fn_generar_poliza_pago_fonaga(
                    :id_pago_garantia
                )
            """), {
                "id_pago_garantia": id_pago_garantia
            })

    return RedirectResponse(
        f"/creditos/{reclamacion['codigo_credito']}",
        status_code=303
    )

@app.get("/fonaga/dashboard")
def dashboard_fonaga(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect
    resumen = fetch_one("""
        SELECT *
        FROM siarc.vw_dashboard_fonaga
        LIMIT 1
    """)

    detalle = fetch_all("""
        SELECT *
        FROM siarc.vw_reclamaciones_garantia
        ORDER BY id_reclamacion DESC
    """)

    return templates.TemplateResponse(
        request,
        "dashboard_fonaga.html",
        {
            "resumen": resumen,
            "detalle": detalle
        }
    )

@app.get("/reportes/cartera")
def reporte_cartera(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect
    datos = fetch_all("""
        SELECT *
        FROM siarc.vw_reporte_cartera_general
        ORDER BY codigo_credito
    """)

    return templates.TemplateResponse(
        request,
        "reporte_cartera.html",
        {"datos": datos}
    )


@app.get("/reportes/cartera/csv")
def descargar_reporte_cartera_csv(request: Request):
    redirect = requiere_login(request)
    if redirect:
        return redirect

    datos = fetch_all("""
        SELECT *
        FROM siarc.vw_reporte_cartera_general
        ORDER BY codigo_credito
    """)

    output = io.StringIO()
    writer = csv.writer(output)

    writer.writerow([
        "codigo_credito",
        "folio_solicitud",
        "nombre_acreditado",
        "curp",
        "rfc",
        "telefono",
        "correo",
        "estado",
        "municipio",
        "localidad",
        "domicilio",
        "actividad_economica",
        "ingresos_mensuales",
        "egresos_mensuales",
        "producto",
        "destino_credito",
        "monto_aprobado",
        "saldo_actual",
        "estatus_credito",
        "dias_atraso",
        "etapa_riesgo",
        "semaforo",
        "pd",
        "lgd",
        "perdida_esperada",
        "fondo_garantia",
        "porcentaje_cobertura",
        "monto_maximo_cubierto",
        "estatus_cobertura"
    ])

    for r in datos:
        writer.writerow([
            r.get("codigo_credito"),
            r.get("folio_solicitud"),
            r.get("nombre_acreditado"),
            r.get("curp"),
            r.get("rfc"),
            r.get("telefono"),
            r.get("correo"),
            r.get("estado"),
            r.get("municipio"),
            r.get("localidad"),
            r.get("domicilio"),
            r.get("actividad_economica"),
            r.get("ingresos_mensuales"),
            r.get("egresos_mensuales"),
            r.get("producto"),
            r.get("destino_credito"),
            r.get("monto_aprobado"),
            r.get("saldo_actual"),
            r.get("estatus_credito"),
            r.get("dias_atraso"),
            r.get("etapa_riesgo"),
            r.get("semaforo"),
            r.get("pd"),
            r.get("lgd"),
            r.get("perdida_esperada"),
            r.get("fondo_garantia"),
            r.get("porcentaje_cobertura"),
            r.get("monto_maximo_cubierto"),
            r.get("estatus_cobertura")
        ])

    output.seek(0)

    return StreamingResponse(
        iter([output.getvalue()]),
        media_type="text/csv",
        headers={
            "Content-Disposition": "attachment; filename=reporte_cartera_siarc.csv"
        }
    )
