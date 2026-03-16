cmake_minimum_required(VERSION 3.10)
project(myproject VERSION 1.0)

add_executable(main main.cpp src/add.cpp)
target_include_directories(main PRIVATE src)

add_library(add PRIVATE src/add.cpp src/add.h)