smokalyzer
==========
Code and design files for a headset-connected device that can detect if you've been smoking.

Info
====
This project is based on the HiJack platform. It includes an interface board designed for use with an electrochemical gas sensor, 3D design files for the creation of an enclosure, and code for iOS and for the HiJack platform that allows for reading and calibration.

What You'll Find Here
=====================

Code for Use With TinyOS
------------------------
Code has been written to be used with the HiJack platform, installed with TinyOS. TinyOS is difficult to setup, but the process should look something like this:

- Check out version 2.1.1 from the TinyOS Subversion page
- Install it on your local machine, including tos-tools. (see documentation on their site)
- Check out the hijack-main code from the google code project and copy the directory structure such that it matches up with your tinyos main folder
- Build the apps using 'make hijack install miniprog bsl,/dev/ttyUSB0'

An iOS App That Displays CO Data
--------------------------------
This is one of my very, very first endeavors into iOS app making. The code is not clean but will hopefully be cleaned up over time. We've imported libHiJack from the HiJack project as well, which requires delicacy when it comes to using ARC. The app supports basic calibration and reading of the instrument. 

Board Design Files
------------------
The files will allow you to order more of the PCB. They have been produced using Eagle 6.3.0.

Enclosure Design Files
----------------------
These files can serve as a starting point for a professional enclosure. They can also be 3D prototyped by any 3D lab for prototype enclosures. 

Questions?
==========
Feel free to contact me with questions. Responses are not guaranteed. 
