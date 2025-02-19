FROM python:3.13.2-slim

# see .dockerignore file for which files are included
COPY ./requirements.txt /requirements.txt

RUN python -m pip install -r /requirements.txt

COPY ./src/ /app

WORKDIR /app

CMD ["uvicorn", "stac_app:app", "--host", "0.0.0.0", "--port", "8000", "--root-path", ""]
