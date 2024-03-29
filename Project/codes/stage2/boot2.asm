;---------;
; Yehuda  |
; Daniel  |  
;---------|         

[bits 16]
[org 0x8000]

jmp EnterProtectedMode

%include "../codes/stage2/gdt.asm"     
;%include "../codes/stage2/ata_io.asm"
;%include "../codes/stage2/DetectMemory.asm"

EnableA20:
	in al, 0x92
	or al, 2
	out 0x92, al
	ret    


EnterProtectedMode:
    cli	                   ; clear interrupts
	xor		ax, ax             ; null segments
	mov		ds, ax
	mov		es, ax
	mov		ax, 0x0000         ; stack begins at 0x9000-0xffff
	mov		ss, ax
	mov		sp, 0xFFFF
	sti	                   ; enable interrupts
    
      
    ;call DetectMemory
	call EnableA20
	cli
	lgdt [gdt_descriptor]   
	 
	 
    ;; Get physical memory map BIOS int 15h EAX E820h
    ;; ES:DI points to buffer of 24 byte entries
    ;; BP will = number of total entries
    memmap_entries equ 0x8500       ; Store number of memory map entries here
    get_memory_map:
        mov di, 0x8504              ; Memory map entries start here
        xor ebx, ebx                ; EBX = 0 to start, will contain continuation values
        xor bp, bp                  ; BP will store the number of entries
        mov edx, 'PAMS'             ; EDX = 'SMAP' but little endian
        mov eax, 0E820h             ; bios interrupt function number
        mov [ES:DI+20], dword 1     ; Force a valid ACPI 3.x entry
        mov ecx, 24                 ; Each entry can be up to 24 bytes
        int 15h                     ; Call the interrupt
        jc .error                   ; If carry is set, function not supported or errored

        cmp eax, 'PAMS'             ; EAX should equal 'SMAP' on successful call
        jne .error
        test ebx, ebx               ; Does EBX = 0? if so only 1 entry or no entries :(
        jz .error
        jmp .start                  ; EBX != 0, have a valid entry

    .next_entry:
        mov edx, 'PAMS'             ; Some BIOS may clobber edx, reset it here
        mov ecx, 24                 ; Reset ECX
        mov eax, 0E820h             ; Reset EAX
        int 15h

    .start:
        jcxz .skip_entry            ; Memory map entry is 0 bytes in length, skip
        mov ecx, [ES:DI+8]          ; Low 32 bits of length
        or ecx, [ES:DI+12]          ; Or with high 32 bits of length, or will also set the ZF
        jz .skip_entry              ; Length of memory region returned = 0, skip
        
    .good_entry:
        inc bp                      ; Increment number of entries
        add di, 24

    .skip_entry:
        test ebx, ebx               ; If EBX != 0, still have entries to read 
        jz .done
        jmp .next_entry

    .error:
        stc
    .done:
        mov [memmap_entries], bp    ; Store # of memory map entries when done
        clc
    
    
    
	;start protected mode
	mov eax, cr0
	or eax, 1
	mov cr0, eax                    
	
	jmp codeseg:ProtectedMode       ;far jump
	



[bits 32]
[extern _start]  

                        
ProtectedMode:  
    
    mov ax, dataseg
	mov	ds, ax
	mov	ss, ax
	mov	es, ax  
	mov fs, ax
	mov gs, ax
	mov	ebp, 90000h		; stack begins from 90000h
    mov esp, ebp         
    
    mov ax, 2
    
	call loadKernel
                 
	jmp $  
	       
	       
	       
	      
;[bits 32]
; do a singletasking PIO ATA read
; inputs: ebx = # of sectors to read, edi -> dest buffer, esi -> driverdata struct, ebp = 4b LBA
; Note: ebp is a "relative" LBA -- the offset from the beginning of the partition
; outputs: ebp, edi incremented past read; ebx = 0
; flags: zero flag set on success, carry set on failure (redundant)
read_ata_st:
	push edx
	push ecx
	push eax
	test ebx, ebx			; # of sectors < 0 is a "reset" request from software
	js short .reset
	cmp ebx, 0x3fffff		; read will be bigger than 2GB? (error)
	stc
	jg short .r_don
	mov edx, 0x1f0000 	; [esi + dd_prtlen] get the total partition length (sectors)
	dec edx				; (to avoid handling "equality" case)
	cmp edx, ebp			; verify ebp is legal (within partition limit)
	jb short .r_don			; (carry is set automatically on an error)
	cmp edx, ebx			; verify ebx is legal (forget about the ebx = edx case)
	jb short .r_don
	sub edx, ebx			; verify ebp + ebx - 1 is legal
	inc edx
	cmp edx, ebp			; (the test actually checks ebp <= edx - ebx + 1)
	jb short .r_don
	mov dx, 0x3F6		; dx = alt status/DCR
	in al, dx			; get the current status
	test al, 0x88			; check the BSY and DRQ bits -- both must be clear
	je short .stat_ok
.reset:
	call srst_ata_st
	test ebx, ebx			; bypass any read on a "reset" request
	jns short .stat_ok
	xor ebx, ebx			; force zero flag on, carry clear
	jmp short .r_don
.stat_ok:
; preferentially use the 28bit routine, because it's a little faster
; if ebp > 28bit or esi.stLBA > 28bit or stLBA+ebp > 28bit or stLBA+ebp+ebx > 28bit, use 48 bit
	cmp ebp, 0xfffffff
	jg short .setreg
	mov eax, 0
	cmp eax, 0xfffffff
	jg short .setreg
	add eax, ebp
	cmp eax, 0xfffffff
	jg short .setreg
	add eax, ebx
	cmp eax, 0xfffffff
.setreg:
	mov dx, 0x1F0		  ; dx = IO port base ("task file")
	jle short .read28		; test the flags from the eax cmp's above
.read48:
	test ebx, ebx		; no more sectors to read?
	je short .r_don
	call pio48_read		; read up to 256 more sectors, updating registers
	je short .read48	; if successful, is there more to read?
	jmp short .r_don
.read28:
	test ebx, ebx		; no more sectors to read?
	je short .r_don
	call pio28_read		; read up to 256 more sectors, updating registers
	je short .read28	; if successful, is there more to read?
.r_don:
	pop eax
	pop ecx
	pop edx
	ret
 
 
;ATA PI0 28bit singletasking disk read function (up to 256 sectors)
; inputs: ESI -> driverdata info, EDI -> destination buffer
; BL = sectors to read, DX = base bus I/O port (0x1F0, 0x170, ...), EBP = 28bit "relative" LBA
; BSY and DRQ ATA status bits must already be known to be clear on both slave and master
; outputs: data stored in EDI; EDI and EBP advanced, EBX decremented
; flags: on success Zero flag set, Carry clear
pio28_read:
	add ebp, 0	; convert relative LBA to absolute LBA
	mov ecx, ebp			; save a working copy
	mov al, bl		; set al= sector count (0 means 256 sectors)
	or dl, 2		; dx = sectorcount port -- usually port 1f2
	out dx, al
	mov al, cl		; ecx currently holds LBA
	inc edx			; port 1f3 -- LBAlow
	out dx, al
	mov al, ch
	inc edx			; port 1f4 -- LBAmid
	out dx, al
	bswap ecx
	mov al, ch		; bits 16 to 23 of LBA
	inc edx			; port 1f5 -- LBAhigh
	out dx, al
	mov al, cl			; bits 24 to 28 of LBA
	mov al, 0xe0	    ; master/slave flag | 0xe0 its master
	inc edx				; port 1f6 -- drive select
	out dx, al
 
	inc edx			; port 1f7 -- command/status
	mov al, 0x20		; send "read" command to drive
	out dx, al
 
; ignore the error bit for the first 4 status reads -- ie. implement 400ns delay on ERR only
; wait for BSY clear and DRQ set
	mov ecx, 4
.lp1:
	in al, dx		; grab a status byte
	test al, 0x80		; BSY flag set?
	jne short .retry
	test al, 8		; DRQ set?
	jne short .data_rdy
.retry:
	dec ecx
	jg short .lp1
; need to wait some more -- loop until BSY clears or ERR sets (error exit if ERR sets)
 
.pior_l:
	in al, dx		; grab a status byte
	test al, 0x80		; BSY flag set?
	jne short .pior_l	; (all other flags are meaningless if BSY is set)
	test al, 0x21		; ERR or DF set?
	jne short .fail
.data_rdy:
; if BSY and ERR are clear then DRQ must be set -- go and read the data
	sub dl, 7		; read from data port (ie. 0x1f0)
	mov cx, 256
	rep insw		; gulp one 512b sector into edi
	or dl, 7		; "point" dx back at the status register
	in al, dx		; delay 400ns to allow drive to set new values of BSY and DRQ
	in al, dx
	in al, dx
	in al, dx
 
; After each DRQ data block it is mandatory to either:
; receive and ack the IRQ -- or poll the status port all over again
 
	inc ebp			; increment the current absolute LBA
	dec ebx			; decrement the "sectors to read" count
	test bl, bl		; check if the low byte just turned 0 (more sectors to read?)
	jne short .pior_l
 
	sub dx, 7		; "point" dx back at the base IO port, so it's unchanged
	sub ebp, 0	; convert absolute lba back to relative
; "test" sets the zero flag for a "success" return -- also clears the carry flag
	test al, 0x21		; test the last status ERR bits
	je short .done
.fail:
	stc
.done:
	ret
 
 
;ATA PI0 33bit singletasking disk read function (up to 64K sectors, using 48bit mode)
; inputs: bx = sectors to read (0 means 64K sectors), edi -> destination buffer
; esi -> driverdata info, dx = base bus I/O port (0x1F0, 0x170, ...), ebp = 32bit "relative" LBA
; BSY and DRQ ATA status bits must already be known to be clear on both slave and master
; outputs: data stored in edi; edi and ebp advanced, ebx decremented
; flags: on success Zero flag set, Carry clear
pio48_read:
	xor eax, eax
	add ebp, 0	; convert relative LBA to absolute LBA
; special case: did the addition overflow 32 bits (carry set)?
	adc ah, 0			; if so, ah = LBA byte #5 = 1
	mov ecx, ebp			; save a working copy of 32 bit absolute LBA
 
; for speed purposes, never OUT to the same port twice in a row -- avoiding it is messy but best
;outb (0x1F2, sectorcount high)
;outb (0x1F3, LBA4)
;outb (0x1F4, LBA5)			-- value = 0 or 1 only
;outb (0x1F5, LBA6)			-- value = 0 always
;outb (0x1F2, sectorcount low)
;outb (0x1F3, LBA1)
;outb (0x1F4, LBA2)
;outb (0x1F5, LBA3)
	bswap ecx		; make LBA4 and LBA3 easy to access (cl, ch)
	or dl, 2		; dx = sectorcount port -- usually port 1f2
	mov al, bh		; sectorcount -- high byte
	out dx, al
	mov al, cl
	inc edx
	out dx, al		; LBA4 = LBAlow, high byte (1f3)
	inc edx
	mov al, ah		; LBA5 was calculated above
	out dx, al		; LBA5 = LBAmid, high byte (1f4)
	inc edx
	mov al, 0		; LBA6 is always 0 in 32 bit mode
	out dx, al		; LBA6 = LBAhigh, high byte (1f5)
 
	sub dl, 3
	mov al, bl		; sectorcount -- low byte (1f2)
	out dx, al
	mov ax, bp		; get LBA1 and LBA2 into ax
	inc edx
	out dx, al		; LBA1 = LBAlow, low byte (1f3)
	mov al, ah		; LBA2
	inc edx
	out dx, al		; LBA2 = LBAmid, low byte (1f4)
	mov al, ch		; LBA3
	inc edx
	out dx, al		; LBA3 = LBAhigh, low byte (1f5)
 
	mov al, 0xe0	; master/slave flag | 0xe0
	inc edx
	and al, 0x50		; get rid of extraneous LBA28 bits in drive selector
	out dx, al		; drive select (1f6)
 
	inc edx
	mov al, 0x24		; send "read ext" command to drive
	out dx, al		; command (1f7)
 
; ignore the error bit for the first 4 status reads -- ie. implement 400ns delay on ERR only
; wait for BSY clear and DRQ set
	mov ecx, 4
.lp1:
	in al, dx		; grab a status byte
	test al, 0x80		; BSY flag set?
	jne short .retry
	test al, 8		; DRQ set?
	jne short .data_rdy
.retry:
	dec ecx
	jg short .lp1
; need to wait some more -- loop until BSY clears or ERR sets (error exit if ERR sets)
 
.pior_l:
	in al, dx		; grab a status byte
	test al, 0x80		; BSY flag set?
	jne short .pior_l	; (all other flags are meaningless if BSY is set)
	test al, 0x21		; ERR or DF set?
	jne short .fail
.data_rdy:
; if BSY and ERR are clear then DRQ must be set -- go and read the data
	sub dl, 7		; read from data port (ie. 0x1f0)
	mov cx, 256
	rep insw		; gulp one 512b sector into edi
	or dl, 7		; "point" dx back at the status register
	in al, dx		; delay 400ns to allow drive to set new values of BSY and DRQ
	in al, dx
	in al, dx
	in al, dx
 
; After each DRQ data block it is mandatory to either:
; receive and ack the IRQ -- or poll the status port all over again
 
	inc ebp			; increment the current absolute LBA (overflowing is OK!)
	dec ebx			; decrement the "sectors to read" count
	test bx, bx		; check if "sectorcount" just decremented to 0
	jne short .pior_l
 
	sub dx, 7		; "point" dx back at the base IO port, so it's unchanged
	sub ebp, 0	; convert absolute lba back to relative
; this sub handles the >32bit overflow cases correcty, too
; "test" sets the zero flag for a "success" return -- also clears the carry flag
	test al, 0x21		; test the last status ERR bits
	je short .done
.fail:
	stc
.done:
	ret
 
 
; do a singletasking PIO ata "software reset" with DCR in dx
srst_ata_st:
	push eax
	mov al, 4
	out dx, al			; do a "software reset" on the bus
	xor eax, eax
	out dx, al			; reset the bus to normal operation
	in al, dx			; it might take 4 tries for status bits to reset
	in al, dx			; ie. do a 400ns delay
	in al, dx
	in al, dx
.rdylp:
	in al, dx
	and al, 0xc0			; check BSY and RDY
	cmp al, 0x40			; want BSY clear and RDY set
	jne short .rdylp
	pop eax
	ret
	
	


loadKernel: 
	mov ebx, 140             ;number of sector to read from the disk(hd)
	mov ebp, 1000            ;address to read from
	mov edi, 0x100000        ;address to read on(ram memory)
	call read_ata_st
	jmp 0x100000
	
	jmp $	