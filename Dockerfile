FROM python:3.12-slim

# see .dockerignore file for which files are included
COPY . /app

WORKDIR /app

RUN python -m pip install -r requirements.txt

CMD ["uvicorn", "stac_app:app", "--host", "0.0.0.0", "--port", "8000", "--root-path", ""]
