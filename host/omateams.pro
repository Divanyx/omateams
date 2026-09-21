QT += quick webenginequick network
CONFIG += c++17
TARGET = omateams

isEmpty(OMATEAMS_VERSION): OMATEAMS_VERSION = dev
DEFINES += OMATEAMS_VERSION=\\\"$${OMATEAMS_VERSION}\\\"

SOURCES += main.cpp Bridge.cpp
HEADERS += Bridge.h
RESOURCES += qml.qrc
