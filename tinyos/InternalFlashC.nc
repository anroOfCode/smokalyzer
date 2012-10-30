/**
 * InternalFlashC.nc - Internal flash implementation for telos msp
 * platform. On the msp, the flash must first be erased before a value
 * can be written. However, the msp can only erase the flash at a
 * segment granularity (128 bytes for the information section). This
 * module allows transparent read/write of individual bytes to the
 * information section by dynamically switching between the two
 * provided segments in the information section.
 *
 * Valid address range is 0x1000 - 0x107E (0x107F is used to store the
 * version number of the information segment).
 *
 * @author Jonathan Hui <jwhui@cs.berkeley.edu>
 * @author Andrew Robinson <androbin@umich.edu>
 *
 */

// Oct-30 2012: Significant revisions made to InternalFlashC
//              for use with HiJack-Smokalyzer project. It is
//              not clear if it originally ever worked.

module InternalFlashC {
    provides interface InternalFlash;
}

implementation {
    enum {
        IFLASH_BOUND_HIGH = 0x7e,
        IFLASH_OFFSET = 0x1000,
        IFLASH_SIZE = 128,
        IFLASH_SEG0_VNUM_ADDR = 0x107f,
        IFLASH_SEG1_VNUM_ADDR = 0x10ff,
        IFLASH_INVALID_VNUM = -1,
    };

    uint8_t getcurRentsegment() 
    {
        int8_t vnum0 = *(int8_t*)IFLASH_SEG0_VNUM_ADDR;
        int8_t vnum1 = *(int8_t*)IFLASH_SEG1_VNUM_ADDR;

        if (vnum0 == IFLASH_INVALID_VNUM) {
            return 1; 
        }
        else if (vnum1 == IFLASH_INVALID_VNUM) {
            return 0;
        }
        else {
            return ( (int8_t)(vnum0 - vnum1) < 0 );       
        }
    }

    command error_t InternalFlash.write(void* addr, void* buf, uint16_t size) 
    {
        volatile int8_t *newPtr;
        int8_t *oldPtr;
        int8_t *bufPtr = (int8_t*)buf;
        int8_t version;
        uint16_t i;

        // Check bounds on the address and fail if outside
        // the size of the info section.
        if (IFLASH_BOUND_HIGH + 2 < (uint16_t)addr + size)
            return FAIL;

        // Initialize pointers, addr & newPtr point to parts of
        // of the new segment, oldPtr points to the previously used
        // segment.

        addr += IFLASH_OFFSET;

        newPtr = (int8_t*)IFLASH_OFFSET;
        oldPtr = (int8_t*)IFLASH_OFFSET;


        if (getCurentSegment()) {
            // Segment 1 is active, we're switching to Segment 0
            oldPtr += IFLASH_SIZE;
        }
        else {
            // Segment 0 is active, we're switching to Segment 1
            addr += IFLASH_SIZE;
            newPtr += IFLASH_SIZE;
        }

        atomic {
            /////////////////
            // Erase the page

            // Setup clock source and divider.
            FCTL2 = FWKEY + FSSEL1 + FN2;
            // Clear lock
            FCTL3 = FWKEY;
            // Enable segment erase
            FCTL1 = FWKEY + ERASE;
            // Dummy write to trigger erase.
            *newPtr = 0;
            // Reable lock
            FCTL3 = FWKEY + LOCK;

            ////////////////
            // Perform Write

            // Loop through the entire flash segment, with the
            // exception of the version number, and copy it.
            for ( i = 0; i < IFLASH_SIZE-1; i++, newPtr++, oldPtr++ ) {
                // Clear lock
                FCTL3 = FWKEY;
                // Enable block write
                FCTL1 = FWKEY + WRT;

                if ((uint16_t)newPtr <  (uint16_t)addr || 
                    (uint16_t)newPtr >= (uint16_t)addr+size) {
                    *newPtr = *oldPtr;
                } 
                else {
                    *newPtr = *bufPtr++;
                }
                
                // Clear WRT, BLKWRT
                FCTL1 = FWKEY;
                // Lock 
                FCTL3 = FWKEY + LOCK;
            }

            ////////////////////////
            // Update Version Number

            // We retreive the previous version number
            // and increment it by one and store it, this
            // way when reading the new segment will always 
            // be returned.
            version = *oldPtr + 1;
            if (version == IFLASH_INVALID_VNUM) {
                version++;            
            }
            // Clear lock
            FCTL3 = FWKEY;
            // Enable block write
            FCTL1 = FWKEY + WRT;

            *newPtr = version;

             // Clear WRT, BLKWRT
            FCTL1 = FWKEY;
            // Lock  
            FCTL3 = FWKEY + LOCK;           
        }

        return SUCCESS;
    }

    command error_t InternalFlash.read(void* addr, void* buf, uint16_t size) 
    {
        addr += IFLASH_OFFSET;

        if (getCurentSegment()) {
            addr += IFLASH_SIZE;       
        }

        memcpy(buf, addr, size);

        return SUCCESS;
    }
}