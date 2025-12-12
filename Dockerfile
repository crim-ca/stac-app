FROM python:3.13.11-slim
LABEL description.short="STAC Populator"
LABEL description.long="CRIM implementation of FastAPI application for SpatioTemporal Asset Catalogs (STAC) for bird-house platform."
LABEL maintainer="Francis Charette-Migneault <francis.charette-migneault@crim.ca>"
LABEL vendor="CRIM"
LABEL version="2.1.0"

# see .dockerignore file for which files are included
COPY LICENSE ./
COPY ./pyproject.toml pyproject.toml

RUN pip install . && rm pyproject.toml

COPY ./src/ /app

WORKDIR /app

CMD ["uvicorn", "stac_app:app", "--host", "0.0.0.0", "--port", "8000", "--root-path", ""]
