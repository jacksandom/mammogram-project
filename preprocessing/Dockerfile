FROM jjanzic/docker-python3-opencv

RUN pip install boto3
RUN pip install numpy
RUN pip install pandas

WORKDIR /usr/local

COPY preprocessing.py preprocessing.py

ENTRYPOINT [ "python", "./preprocessing.py" ]
CMD [ "--infile=test" ]