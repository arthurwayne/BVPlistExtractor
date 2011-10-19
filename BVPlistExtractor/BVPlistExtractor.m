//
// PlistExtractor.c
//
// Copyright (C) 2011 by Bavarious
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <mach/machine.h>
#include <sys/mman.h>
#include <sys/stat.h>
#import <Foundation/Foundation.h>

#include "BVPlistExtractor.h"

static NSData *_BVMachOSection(NSURL *url, char *segname, char *sectname, NSError **error);
static NSData *_BVMachOSectionFromMachOHeader(char *addr, char *segname, char *sectname, NSError **error);
static NSData *_BVMachOSectionFromMachOHeader32(char *addr, char *segname, char *sectname, NSError **error);
static NSData *_BVMachOSectionFromMachOHeader64(char *addr, char *segname, char *sectname, NSError **error);

id BVExtractPlist(NSURL *url, NSError **error) {
    id plist = nil;
    NSData *data = _BVMachOSection(url, "__TEXT", "__info_plist", error);
    if (data) {
        plist = [NSPropertyListSerialization propertyListWithData:data
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:error];

    }
    return plist;
}

NSData *_BVMachOSection(NSURL *url, char *segname, char *sectname, NSError **error) {
    NSData *data = nil;
    int fd;
    struct stat stat_buf;
    size_t size;
    
    char *addr = NULL;
    char *start_addr = NULL;
    
    // Open the file and get its size
    fd = open([[url path] UTF8String], O_RDONLY);
    if (fd == -1) goto END_FUNCTION;
    if (fstat(fd, &stat_buf) == -1) goto END_FILE;
    size = stat_buf.st_size;
    
    // Map the file to memory
    addr = start_addr = mmap(0, size, PROT_READ, MAP_FILE | MAP_PRIVATE, fd, 0);
    if (addr == MAP_FAILED) goto END_FILE;
    
    // Check if it's a fat file
    struct fat_header *fh = (struct fat_header *)addr;
    uint32_t magic = NSSwapBigIntToHost(FAT_MAGIC);
    
    // It's a fat file
    if (fh->magic == magic) {
        int nfat_arch = NSSwapBigIntToHost(fh->nfat_arch);
        addr += sizeof(struct fat_header);
        
        // Read the architectures
        for (int ifat_arch = 0; ifat_arch < nfat_arch; ifat_arch++) {
            struct fat_arch *fa = (struct fat_arch *)addr;
            int offset = NSSwapBigIntToHost(fa->offset);
            addr += sizeof(struct fat_arch);
            data = _BVMachOSectionFromMachOHeader(start_addr + offset, segname, sectname, error);
            if (data) break;
        }
    }
    // It's a thin file
    else {
        data = _BVMachOSectionFromMachOHeader(start_addr, segname, sectname, error);
    }
    
END_MMAP:
    munmap(addr, size);
    
END_FILE:
    close(fd);
    
END_FUNCTION:
    return data;
}

NSData *_BVMachOSectionFromMachOHeader(char *addr, char *segname, char *sectname, NSError **error) {
    NSData *data = nil;
    struct mach_header *mh;

    // The first bytes are the Mach-O header
    mh = (struct mach_header *)addr;
    
    if (mh->magic == MH_MAGIC) { // 32-bit
        data = _BVMachOSectionFromMachOHeader32(addr, segname, sectname, error);
    }
    else if (mh->magic == MH_MAGIC_64) { // 64-bit
        data = _BVMachOSectionFromMachOHeader64(addr, segname, sectname, error);
    }
    
    return data;
}

NSData *_BVMachOSectionFromMachOHeader32(char *addr, char *segname, char *sectname, NSError **error) {
    NSData *data = nil;
    char *base_macho_header_addr = addr;
    struct mach_header *mh = NULL;
    struct load_command *lc = NULL;
    struct segment_command *sc = NULL;
    struct section *sect = NULL;
    
    mh = (struct mach_header *)addr;
    addr += sizeof(struct mach_header);
    
    for (int icmd = 0; icmd < mh->ncmds; icmd++) {
        lc = (struct load_command *)addr;
        
        if (lc->cmdsize == 0) continue;
        
        if (lc->cmd != LC_SEGMENT) {
            addr += lc->cmdsize;
            continue;
        }
        
        // It's a 32-bit segment
        sc = (struct segment_command *)addr;
        
        if (strcmp(segname, sc->segname) != 0 || sc->nsects == 0) {
            addr += lc->cmdsize;
            continue;
        }
        
        // It's the __TEXT segment and it has at least one section
        // Section data follows segment data
        addr += sizeof(struct segment_command);
        for (int isect = 0; isect < sc->nsects; isect++) {
            sect = (struct section *)addr;
            addr += sizeof(struct section);
            
            if (strcmp(sectname, sect->sectname) != 0) continue;
            
            // It's the __TEXT __info_plist section
            
            data = [NSData dataWithBytes:(base_macho_header_addr + sect->offset) length:sect->size];
            goto END_FUNCTION;
        }
    }
    
END_FUNCTION:
    return data;
}

NSData *_BVMachOSectionFromMachOHeader64(char *addr, char *segname, char *sectname, NSError **error) {
    NSData *data = nil;
    char *base_macho_header_addr = addr;
    struct mach_header_64 *mh = NULL;
    struct load_command *lc = NULL;
    struct segment_command_64 *sc = NULL;
    struct section_64 *sect = NULL;
    
    mh = (struct mach_header_64 *)addr;
    addr += sizeof(struct mach_header_64);
    
    for (int icmd = 0; icmd < mh->ncmds; icmd++) {
        lc = (struct load_command *)addr;
        
        if (lc->cmd != LC_SEGMENT_64) {
            addr += lc->cmdsize;
            continue;
        }

        if (lc->cmdsize == 0) continue;
        
        // It's a 64-bit segment
        sc = (struct segment_command_64 *)addr;
        
        if (strcmp(segname, sc->segname) != 0 || sc->nsects == 0) {
            addr += lc->cmdsize;
            continue;
        }
        
        // It's the __TEXT segment and it has at least one section
        // Section data follows segment data
        addr += sizeof(struct segment_command_64);
        for (int isect = 0; isect < sc->nsects; isect++) {
            sect = (struct section_64 *)addr;
            addr += sizeof(struct section_64);
            
            if (strcmp(sectname, sect->sectname) != 0) continue;
            
            // It's the __TEXT __info_plist section
            data = [NSData dataWithBytes:(base_macho_header_addr + sect->offset) length:sect->size];
            goto END_FUNCTION;
        }
    }
    
END_FUNCTION:
    return data;
}
