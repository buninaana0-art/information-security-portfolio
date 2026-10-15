.model small
.386
.stack 100h
.data
	Buffer 	db 	1024 DUP(?)
	A 	db 	'com.com',0
	C 	db 	'vivod.asm',0
	_BSR	db	9,'BSR',9,'$'
	_SAHF	db	9,'sahf',13,10,'$'
	reg	db	'  ','$'
	zap	db	',','$'
	entr	db	13,10,'$'	
	point	db	':','$'		;для [eax] 32
	_plus	db	'+','$'
	ad1 	db 	'[','$'
	ad2 	db 	']','$'
	_e 	db 	'e','$'
	_bx_si	db	'bx+si','$'
	_bx_di	db	'bx+di','$'
	_bp_si	db	'bp+si','$'
	_bp_di	db	'bp+di','$'
	_si	db	'si','$'
	_di	db	'di','$'
	_bp	db	'bp','$'
	_bx	db	'bx','$'
	_ax	db	'ax','$'
	_cx	db	'cx','$'
	_dx	db	'dx','$'
	var_sm	db	'  h','$'	
	var_mid	db	'    h','$'
	var_big	db	'        h','$'	
.code
start:	
	mov 	ax,@data	
	mov 	ds,ax
	mov	es,ax
	lea	dx,a
	mov	ax,3d00h
	int	21h
	mov	bx,ax
	mov	ax,3f00h
	mov	cx,1024d
	lea	dx,buffer
	int	21h
	mov	ax,3e00h
	int	21h
	lea	dx,c
	mov	ax,3c00h
	mov	cx,2
	int	21h
	lea	si,buffer
nachalo:
	xor	bp,bp
	xor	ah,ah
	lodsb
	cmp 	al,66h
	jz	i_66
seg_reg:
	cmp    	al,26h
  	jz	Z
    	cmp    	al,2Eh
 	jz	Z
    	cmp    	al,36h
	jz	Z
	cmp    	al,3Eh
	jz	Z
	cmp    	al,64h
	jz	Z
    	cmp    	al,65h
    	jnz    	ZZ
Z:
	or	bp,ax		
	lodsb
ZZ:
	cmp 	al,67h
	jz	i_67
OP_code:
	cmp	al,9Eh             
	jz	_SAHF_ZAPIS
	cmp	al, 0Fh             
	jnz	exit
	lodsb
	cmp	al,0BDh
	jnz	exit
	lea	dx,_BSR             	
	mov	cx,5
	call	ZAPIS
	pusha				
	and	bp,1000h
	cmp	bp,1000h
	jnz	pol
	lea	dx,_e             
	mov	cx,1
	call	ZAPIS	
pol:
	popa
	call	mod_reg_rm		
	pusha
	call	reg_16			
	popa
	cmp	bh, 3
	jnz	_bsr_
	pusha				
	call	mod11
	popa
	jmp	end_bsr
_bsr_:
	pusha
	call	seg_ment		
	popa
	pusha
	lea	dx,ad1			
	mov	cx,1
	call	ZAPIS
	popa		
	and	bp,0100h		
	cmp	bp,0100h
	jnz	tab_16			
	pusha
	call	MEM_32			
	popa
	cmp	bh,0			
	jz	ckoda_2
	cmp	bh,1
	jz	_disp8
	cmp	bh,2
	jz	_disp32
tab_16:
	pusha
	call	MEM_16			
	popa
	cmp	bh,0			
	jz	ckoda_2
	cmp	bh,1
	jz	_disp8
	cmp	bh,2
	jz	_disp16
ckoda_2:
	lea	dx,ad2			
	mov	cx,1
	call	ZAPIS
end_bsr:
	lea	dx,entr
	mov	cx,2
	call	ZAPIS
	jmp	nachalo
mod_reg_rm:
	shr	al,1
	rcl	ah,1
	lodsb
	mov	bl,al
	and	bl,7     
	mov	bh,al
	shr	bh,6	 
	shr	al,3	 
	and	al,7
	ret
i_66:
	or	bp,1000h
	lodsb
	jmp	seg_reg	
i_67:
	or	bp,0100h
	lodsb
	jmp	OP_code
_disp8:
	lea	dx,_plus	
	mov 	cx,1
	call	ZAPIS
	lodsb	
	lea	di,[var_sm]
	mov	cx, 2		
	mov	bh, al
	call	number
	lea	dx,var_sm	
	mov	cx,3
	call	ZAPIS
	jmp	ckoda_2
_disp16:
	lea	dx,_plus	
	mov 	cx,1
	call	ZAPIS
	lodsw	
	lea	di,[var_mid]
	mov	cx, 4		
	mov	bx,ax
	call	number
	lea	dx,var_mid	
	mov	cx,5
	call	ZAPIS
	jmp	ckoda_2
_disp32:
	lea	dx,_plus	
	mov 	cx,1
	call	ZAPIS
	lodsw
	lea	di,[var_big+4]
	mov	cx, 4		
	mov	bx,ax
	call	number
	lodsw
	lea	di,[var_big]
	mov	cx, 4	
	mov	bx,ax
	call	number
	lea	dx,var_big	
	mov	cx,9
	call	ZAPIS
	jmp	ckoda_2
reg_16:
	lea	di,reg
	lea	dx,reg
	mov	cx,2
	cmp 	al,0
	jz	reg_ax
	cmp 	al,1
	jz	reg_cx
	cmp 	al,2
	jz	reg_dx
	cmp 	al,3
	jz	reg_bx
	cmp 	al,4
	jz	reg_sp
	cmp 	al,5
	jz	reg_bp
	cmp 	al,6
	jz	reg_si
	cmp 	al,7
	jz	reg_di
reg_ax:
	mov	ax, 'xa'
	jmp	zap_reg
reg_cx:
	mov	ax, 'xc'
	jmp	zap_reg
reg_dx:
	mov	ax, 'xd'
	jmp	zap_reg
reg_bx:
	mov	ax, 'xb'
	jmp	zap_reg
reg_sp:
	mov	ax, 'ps'
	jmp	zap_reg
reg_bp:
	mov	ax, 'pb'
	jmp	zap_reg
reg_si:
	mov	ax, 'is'
	jmp	zap_reg
reg_di:
	mov	ax, 'id'
	jmp	zap_reg
zap_reg:
	stosw
	call	ZAPIS	
	call	zap_zap
	ret
seg_ment:
	and	bp,00FFh		
	cmp	bp,0
	jz	m_7
	lea	di, reg
	lea	dx, reg
	mov	cx,2
	cmp	bp,0026h
	jnz	m_1
	mov	ax,'se'
	jmp	m_6
m_1:
	cmp	bp,002Eh
	jnz	m_2
	mov    	ax,'sc'
    	jmp    	m_6
m_2:
	cmp	bp,0036h
	jnz	m_3
	mov    	ax,'ss'                       
    	jmp    	m_6
m_3:
	cmp	bp, 003Eh
	jnz	m_4
	mov	ax,'sd'
	jmp	m_6
m_4:
	cmp	bp,0064h
	jnz	m_5
	mov	ax,'sf'
	jmp	m_6
m_5:
	cmp	bp,0065h
	jnz	m_7
	mov	ax,'sg'
m_6:
	stosw
	call ZAPIS
	lea	dx, point
	mov	cx,1
	call	ZAPIS
m_7:
	ret
mod11:	
	pusha
	and	bp,1000h
	cmp	bp,1000h
	jnz	next_1
	lea	dx,_e             
	mov	cx,1
	call	ZAPIS	
next_1:	
	popa		
	lea	di,reg	
	lea	dx,reg
	mov	cx,2
	cmp	bl,0
	jnz	p0
	mov	ax,'xa'	
	jmp	y
p0:
	cmp	bl,1
	jnz	p1
	mov	ax,'xc'
	jmp	y
p1:
	cmp	bl,2
	jnz	p2
	mov	ax,'xd'	
	jmp	y
p2:
	cmp	bl,3
	jnz	p3
	mov	ax,'xb'
	jmp	y
p3:
	cmp	bl,4
	jnz	p4
	mov	ax,'ps'
	jmp	y
p4:
	cmp	bl,5
	jnz	p5
	cmp	ah,0
	mov	ax,'pb'	
	jmp	y
p5:
	cmp	bl,6
	jnz	p6
	mov	ax,'is'
	jmp	y	
p6:
	mov	ax,'id'
y:
	stosw
	call	ZAPIS
	ret
MEM_16:	
	cmp	bl,0
	jnz	_001
	lea	dx, _bx_si
	mov	cx, 5
	jmp	end_MEM_16
_001:
	cmp	bl,1
	jnz	_010
	lea	dx, _bx_di
	mov	cx, 5
	jmp	end_MEM_16
_010:
	cmp	bl,2
	jnz	_011
	lea	dx, _bp_si
	mov	cx, 5
	jmp	end_MEM_16
_011:
	cmp	bl,3
	jnz	_100
	lea	dx, _bp_di
	mov	cx, 5
	jmp	end_MEM_16
_100:
	cmp	bl,4
	jnz	_101
	lea	dx, _si
	mov	cx, 2
	jmp	end_MEM_16
_101:
	cmp	bl,5
	jnz	_110
	lea	dx, _di
	mov	cx, 2
	jmp	end_MEM_16
_110:
	cmp	bl,6
	jnz	_111
	cmp	bh, 0
	jnz	_110_mod
	lodsw
	pusha
	lea	di,[var_mid]
	mov	bx,ax		
	mov	cx, 4		
	call	number
	lea	dx,var_mid	
	mov	cx,5
	call	ZAPIS
	popa
	ret
_110_mod:
	lea	dx, _bp
	mov	cx, 2
	jmp	end_MEM_16
_111:
	lea	dx, _bx
	mov	cx, 2
	jmp	end_MEM_16
end_MEM_16:
	call	ZAPIS
	ret
MEM_32:	
	pusha
	lea	dx,_e             	
	mov	cx,1
	call	ZAPIS
	popa
	cmp	bl,0
	jnz	_001_
	lea	dx, _ax
	jmp	end_MEM_32
_001_:
	cmp	bl,1
	jnz	_010_
	lea	dx, _cx
	jmp	end_MEM_32
_010_:
	cmp	bl,2
	jnz	_011_
	lea	dx, _dx
	jmp	end_MEM_32
_011_:
	cmp	bl,3
	jnz	_100_
	lea	dx, _bx
	jmp	end_MEM_32
_100_:					
	cmp	bl,4
	jnz	_101_
	call	exit
	ret				
_101_:
	cmp	bl,5
	jnz	_110_
	cmp	bh,0
	jnz	_101_1_
	call	exit
_101_1_:
	lea	dx, _bp
	jmp	end_MEM_32
_110_:
	cmp	bl,6
	jnz	_111_
	lea	dx, _si
	jmp	end_MEM_32
_111_:
	lea	dx, _di
end_MEM_32:
	mov	cx, 2
	call	ZAPIS
	ret
number:
	xor	al,al
	mov	dx,cx
	mov	cx,4
circle:
	shl 	bx,1
     	rcl 	al,1
	loop	circle
	cmp	al,0Ah
	jb	cifra
	add	al,7h
cifra:
	add	al, 30h
	stosb
	mov	cx,dx
	loop	number
	ret
zap_zap:
	lea	dx,zap
	mov 	cx,1
	call	ZAPIS
	ret
ZAPIS:
	mov	ah,40h
	mov	bx,5
	int	21h                                 
	mov 	ah,09h
	int 	21h
	ret
_SAHF_ZAPIS:
	mov	cx,7
	lea	dx,_SAHF
	call	ZAPIS
	jmp	nachalo
exit:
	mov 	ax, 4c01h          
	int 	21h
end	start
