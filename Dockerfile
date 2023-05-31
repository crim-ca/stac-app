
FROM python:3.8-slim as base

FROM base as builder
# Any python libraries that require system libraries to be installed will likely
# need the following packages in order to build
RUN apt-get update && apt-get install -y build-essential git

ENV CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ENV PATH=$PATH:/install/bin

ARG install_dev_dependencies=true

# TODO : temporary fix
RUN git clone https://github.com/stac-utils/stac-fastapi.git

WORKDIR /stac-fastapi

RUN pip install \
      -e stac_fastapi/api \
      -e stac_fastapi/types \
      -e stac_fastapi/extensions
RUN pip install pypgstac

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive \
    apt-get install --no-install-recommends --assume-yes \
      postgresql-client

COPY . /app

WORKDIR /app

RUN pip install -r requirements.txt

CMD ["uvicorn", "stac_app:app", "--reload", "--host", "0.0.0.0", "--port", "8000", "--root-path", ""]
