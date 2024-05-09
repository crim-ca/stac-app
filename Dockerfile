
FROM python:3.13.0b1-slim as base

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

# TODO : checkout to working November 25 2022 version of stac-fastapi, where pgstac was bundled in stac-fastapi (now `pip install pypgstac`)
RUN git checkout d53e792

RUN pip install \
      -e stac_fastapi/api \
      -e stac_fastapi/types \
      -e stac_fastapi/extensions
RUN pip install -e stac_fastapi/pgstac

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive \
    apt-get install --no-install-recommends --assume-yes \
      postgresql-client

COPY . /app

WORKDIR /app

RUN pip install -r requirements.txt

CMD ["uvicorn", "stac_app:app", "--reload", "--host", "0.0.0.0", "--port", "8000", "--root-path", ""]
