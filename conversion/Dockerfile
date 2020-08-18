FROM jjanzic/docker-python3-opencv

RUN pip install boto3
RUN pip install pydicom

WORKDIR /usr/local

COPY conversion.py conversion.py

ENTRYPOINT [ "python", "./conversion.py" ]
CMD [ "--infile=test" ]