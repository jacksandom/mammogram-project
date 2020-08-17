import boto3
import os
import multiprocessing as mp
import cv2
from matplotlib import path
import numpy as np
import pandas as pd
from urllib.request import urlretrieve


def download_s3_folder(bucketName, directoryName):
    s3_resource = boto3.resource('s3')
    bucket = s3_resource.Bucket(bucketName)
    objects = bucket.objects.filter(Prefix=directoryName)
    for obj in objects:
        if not os.path.exists(os.path.dirname(obj.key)):
            os.makedirs(os.path.dirname(obj.key))
        if os.path.split(obj.key)[1] != '':
            bucket.download_file(obj.key, obj.key)


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
        p = path.Path(vertices)
        mask = np.logical_or(mask, p.contains_points(index_img).reshape(img.shape[0], img.shape[1], order='F').astype(np.uint8))

    # overwrite boxes
    img[mask] = 0
    
    return img


def resize_image(img):
    return cv2.resize(img, (512,512))


def train_test_dir(imgPath, labelsFile):
    (root,file) = imgPath
    
    # retrive patient id to find label
    p_id = '_'.join([root.split('/')[1].split('_')[1], root.split('/')[1].split('_')[2]])
    label = labelsFile[labelsFile['patient_id'] == p_id]['pathology'].to_string(index=False)
    
    train_or_test = 'Train' if 'Training' in root else 'Test'
    new_root = os.path.join('PNG-Images-Processed',train_or_test, label.strip())
    new_file = p_id + '.png'
    return(new_root, new_file)


def process_png(file_path):

    (curr_root, curr_file, new_root, new_file) = file_path
    
    img = cv2.imread(os.path.join(curr_root, curr_file), 0)
    unmarked_img = remove_marks(img)
    resized_img = resize_image(unmarked_img)

    if not os.path.exists(new_root):
        os.makedirs(new_root)
    cv2.imwrite(os.path.join(new_root, new_file).replace('\\', '/'), resized_img)


def upload_s3_folder(bucketName):
    s3 = boto3.client('s3')
    for root,dirs,files in os.walk('PNG-Images-Processed'):
        for file in files:
            s3.upload_file(os.path.join(root,file), bucketName, os.path.join(root,file).replace('\\', '/'))


if __name__ == '__main__':

    bucket_name = 'mammogram-images'
    png_directory_name = 'PNG-Images'

    download_s3_folder(bucket_name, png_directory_name)

    # download training and testing description CSVs
    urlretrieve("https://wiki.cancerimagingarchive.net/download/attachments/22516629/calc_case_description_train_set.csv?version=1&modificationDate=1506796349666&api=v2", "train-description.csv")
    urlretrieve("https://wiki.cancerimagingarchive.net/download/attachments/22516629/calc_case_description_test_set.csv?version=1&modificationDate=1506796343686&api=v2", "test-description.csv")

    train_description = pd.read_csv('train-description.csv')
    test_description = pd.read_csv('test-description.csv')
    labels = pd.concat([train_description, test_description])[['patient_id', 'pathology']]
    labels = labels.replace('BENIGN_WITHOUT_CALLBACK', 'BENIGN')
    labels = labels.drop_duplicates()

    file_paths = []
    for root, dirs, files in os.walk(png_directory_name):
            for file in files:
                if file.endswith(".png"):
                    # append new file path for model training
                    (new_root, new_file) = train_test_dir((root.replace('\\', '/'), file), labels)
                    file_paths.append((root.replace('\\', '/'), file, new_root.replace('\\', '/'), new_file))

    pool = mp.Pool()
    pool.map(process_png, file_paths)
    pool.close()

    upload_s3_folder(bucket_name)
