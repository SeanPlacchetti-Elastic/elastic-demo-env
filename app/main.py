from elasticapm.contrib.starlette import ElasticAPM, make_apm_client
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
import os

try:
    apm = make_apm_client({
        'SERVICE_NAME': os.environ.get('ELASTIC_APM_SERVICE_NAME', 'apm-demo'),
        'SECRET_TOKEN': os.environ.get('ELASTIC_APM_SECRET_TOKEN', 'supersecrettoken'),
        'SERVER_URL': os.environ.get('ELASTIC_APM_SERVER_URL', 'http://apm-server:8200'),
        'ENVIRONMENT': os.environ.get('ELASTIC_APM_ENVIRONMENT', 'development'),
    })
except Exception as e:
    print(f'failed to create APM client: {e}')
    apm = None

app = FastAPI()

try:
    app.add_middleware(ElasticAPM, client=apm)
except Exception as e:
    print(f'failed to add APM middleware: {e}')

templates = Jinja2Templates(directory="templates")


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("index.html", {
        "request": request,
        "service_name": os.environ.get('ELASTIC_APM_SERVICE_NAME', 'apm-demo'),
        "environment": os.environ.get('ELASTIC_APM_ENVIRONMENT', 'development'),
        "apm_server_url": os.environ.get('ELASTIC_APM_SERVER_URL', 'http://apm-server:8200'),
        "rum_server_url": os.environ.get('RUM_SERVER_URL', 'http://localhost:8200'),
    })


@app.get("/custom_message/{message}")
async def custom_message(message: str):
    if apm:
        apm.capture_message(f"Custom Message: {message}")
    return {"message": f"Custom Message: {message}"}


@app.get("/error")
async def throw_error():
    try:
        1 / 0
    except Exception:
        if apm:
            apm.capture_exception()
    return {"message": "Failed Successfully :)"}


try:
    if apm:
        apm.capture_message('App Loaded, Hello World!')
except Exception as e:
    print(f'error: {e}')

if __name__ == '__main__':
    print('Please start with the uvicorn command as shown in the dockerfile')
