.model tiny
.486
.data
.code
org 100h
start:	

	sahf
	bsr	ax,bx
	bsr	cx,dx
	bsr	si,bp
	bsr	di,sp
	bsr	cx,gs:[bx+si]
	bsr	bp,[bx+di]
	bsr	ax,ss:[bp+si]
	bsr	dx,[si]
	bsr	si,[di]
	bsr	sp,ss:[bx]
	bsr	eax, dword ptr ds:[si]
	bsr	eax,esp
	bsr	ecx, dword ptr [bx+si+56h]
	bsr	si, fs:[bx+di+12h]
	bsr	eax, dword ptr [edi]
	bsr	sp,[bx+si+41h]
	bsr	edi, dword ptr [bx+di+76h]
	bsr	bp,[bp+si+0ABh]
	bsr	cx,es:[bp+di+0EDh]
	bsr	di,[si+89h]
	bsr	ax,[di+67h]
	bsr	bx,cs:[bp+0DBh]
	bsr	ebp, dword ptr [bx+02Ch]
	bsr	esi, dword ptr [bx+si+9768h]
	bsr	ebp, dword ptr [bx+di+0FC92h]
	bsr	edx, dword ptr [bp+si+12A3h]
	bsr	dx, [bp+di+7654h]
	bsr	bx, [si+0BAC6h]
	bsr	bp, [di+0AAAAh]
	bsr	si, [bp+8765h]
	bsr	cx, [bx+0CACAh]
	bsr	ax,[ecx+65h]
	bsr	cx,[eax+0ACh]
	bsr	si,[edx+76h]
	bsr	di,[ebx+0BDh]
	bsr	sp,[esi+81h]
	bsr	bp,[edi+67h]
	bsr	ax,[ecx]
	bsr	cx,[eax]
	bsr	si,[edx]
	bsr	di,[ebx]
	bsr	sp,[esi]
	bsr	bp,[edi]	
	bsr	ax,[ecx+6876h]
	bsr	cx,[eax+0ACh]
	bsr	si,[edx+2345h]
	bsr	di,[ebx+0BDh]
	bsr	sp,[esi+3847h]
	bsr	bp,[edi+8237h]
	
	
end start