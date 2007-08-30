-------------------------------------------------------------------------------
--  Ada implementation of atomic multi-word register based on the algorithm
--  by in [A. Larsson, A. Gidenstam, P. H. Ha, M. Papatriantafilou,
--  P. Tsigas, "Multi-word Atomic Read/Write Registers on Multiprocessor
--  Systems", European Symposium on Algorithms, 2004].
--
--  Copyright (C) 2007  Anders Gidenstam
--
--  This program is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; either version 2 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program; if not, write to the Free Software
--  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
--
-------------------------------------------------------------------------------
pragma Style_Checks (Off);
-------------------------------------------------------------------------------
--                              -*- Mode: Ada -*-
--  Filename        : atomic_single_writer_registers.ads
--  Description     : Ada implementation of atomic multi-word register.
--                    Based on A. Larsson, A. Gidenstam, P. H. Ha,
--                    M. Papatriantafilou, P. Tsigas,
--                    "Multi-word Atomic Read/Write Registers on Multiprocessor
--                    Systems", Proceedings of the 12th Annual European
--                    Symposium on Algorithms, LNCS 3221 pages 736--748, 2004.
--  Author          : Anders Gidenstam
--  Created On      : Tue Aug 28 18:12:00 2007
--  $Id: nbada-atomic_single_writer_registers.ads,v 1.1 2007/08/29 14:25:44 andersg Exp $
-------------------------------------------------------------------------------
pragma Style_Checks (All_Checks);

pragma License (GPL);

with Primitives;

generic
   type Element_Type is private;

package Atomic_Single_Writer_Registers is

   pragma Pure;

   type Atomic_1_M_Register (No_Of_Readers : Positive) is limited private;

   procedure Write (Register : in out Atomic_1_M_Register;
                    Value    : in     Element_Type);
   procedure Read  (Register  : in out Atomic_1_M_Register;
                    Reader_No : in     Positive;
                    Value     :    out Element_Type);

private

   subtype Index is Integer range -1 .. Integer'Last;

   type Element_Array is array (Index range <>) of Element_Type;
   pragma Volatile_Components (Element_Array);

   type    Trace_Array is array (Positive range <>) of Index;

   type Atomic_1_M_Register (No_Of_Readers : Positive) is
      record
         SYNC  : aliased Primitives.Standard_Unsigned := 0;
         BUF   : Element_Array (Index'First .. No_Of_Readers);
         --  Persistent state for the writer.
         Trace : Trace_Array (1 .. No_Of_Readers) := (others => 0);
         Last  : Index := 0;
      end record;

end Atomic_Single_Writer_Registers;
