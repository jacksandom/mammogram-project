import boto3
import os
import multiprocessing as mp
import cv2
import matplotlib as plt
import numpy as np
import pandas as pd
from urllib.request import urlretrieve
import sys


def download_s3_file(bucketName, filePath):
    s3_resource = boto3.resource('s3')
    bucket = s3_resource.Bucket(bucketName)
    if not os.path.exists(os.path.dirname(filePath)):
        os.makedirs(os.path.dirname(filePath))
        bucket.download_file(filePath, filePath)


def remove_marks(img):
    
    # Separate background from non-background
    binary_img = np.where(img > 5, 1, 0).astype(np.uint8)

    # find image contours
    contours, _ = cv2.findContours(binary_img, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)[-2:]

    # calculate bounding box for each contours
    boxes = [(c,cv2.minAreaRect(c)) for c in contours]

    # filter boxes based on area threshold
    large_boxes = []
    for box in boxes:
        w,h = box[1][1]
        if w*h > 1000: # threshold
            large_boxes.append(box)
            
    # sort by area
    boxes.sort(key=lambda box: box[1][1][0]*box[1][1][1])
    
    # filter top 10 (not including largest box which is tissue)
    boxes = boxes[-10:-1]

    # calculate coordinates
    coords = []
    for box in boxes:
        coords.append(np.int0(cv2.boxPoints(box[1])))

    # finally, create bool mask
    y_dim = np.arange(0, img.shape[0], step=1)
    x_dim = np.arange(0, img.shape[1], step=1)
    index_img = np.array(np.meshgrid(x_dim, y_dim)).T.reshape(-1,2)

    mask = np.zeros((img.shape[0], img.shape[1]), dtype=bool)
    for vertices in coords:
        p = plt.path.Path(vertices)
        mask = np.logical_or(mask, p.contains_points(index_img).reshape(img.shape[0], img.shape[1], order='F').astype(np.uint8))

    # overwrite boxes
    img[mask] = 0
    
    return img


def resize_image(img):
    return cv2.resize(img, (512,512))


def train_test_dir(imgPath, labelsFile):
    # retrive patient id to find label
    p_id = '_'.join([imgPath.split('/')[1].split('_')[1], imgPath.split('/')[1].split('_')[2]])
    label = labelsFile[labelsFile['patient_id'] == p_id]['pathology'].to_string(index=False)
    
    train_or_test = 'Train' if 'Training' in imgPath else 'Test'
    new_path = os.path.join('PNG-Images-Processed',train_or_test, label.strip(), p_id + '.png')
    return new_path


def process_png(file_path):

    (bucket, path, new_path) = file_path
    
    img = cv2.imread(path, 0)
    unmarked_img = remove_marks(img)
    resized_img = resize_image(unmarked_img)

    if not os.path.exists('/'.join(new_path.split('/')[:-1])):
        os.makedirs('/'.join(new_path.split('/')[:-1]))
    cv2.imwrite(new_path.replace('\\', '/'), resized_img)


def upload_s3_file(bucketName, filePath):
    s3 = boto3.client('s3')
    s3.upload_file(filePath, bucketName, filePath)


def preprocess(filePath):
    download_s3_file(filePath[0], filePath[1])
    process_png(filePath)
    upload_s3_file(filePath[0], filePath[2])
    os.remove(filePath[1])
    os.remove(filePath[2])


if __name__ == '__main__':

    #bucket_name = sys.argv[1]
    bucket_name = 'mammogram-images'
    png_directory_name = 'PNG-Images'

    # download training and testing description CSVs
    urlretrieve("https://wiki.cancerimagingarchive.net/download/attachments/22516629/calc_case_description_train_set.csv?version=1&modificationDate=1506796349666&api=v2", "train-description.csv")
    urlretrieve("https://wiki.cancerimagingarchive.net/download/attachments/22516629/calc_case_description_test_set.csv?version=1&modificationDate=1506796343686&api=v2", "test-description.csv")

    train_description = pd.read_csv('train-description.csv')
    test_description = pd.read_csv('test-description.csv')
    labels = pd.concat([train_description, test_description])[['patient_id', 'pathology']]
    labels = labels.replace('BENIGN_WITHOUT_CALLBACK', 'BENIGN')
    labels = labels.drop_duplicates()

    file_paths = []
    s3_resource = boto3.resource('s3')
    bucket = s3_resource.Bucket(bucket_name)
    objects = bucket.objects.filter(Prefix=png_directory_name)
    for obj in objects:
        file_paths.append((bucket_name, obj.key))

    new_file_paths = []
    for bucket, path in file_paths:
        if path.endswith(".png"):
            # append new file path for model training
            new_path = train_test_dir(path, labels)
            new_file_paths.append((bucket, path, new_path.replace('\\', '/')))

    pool = mp.Pool()
    pool.map(preprocess, new_file_paths)
    pool.close()
