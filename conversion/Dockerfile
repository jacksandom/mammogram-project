FROM python:3.7

RUN pip install boto3
RUN pip install pydicom
RUN pip install opencv-python

WORKDIR /usr/local

COPY conversion.py conversion.py

ENTRYPOINT [ "python", "./conversion.py" ]
CMD [ "--infile=test" ]