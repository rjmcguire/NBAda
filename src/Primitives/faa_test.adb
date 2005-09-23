-------------------------------------------------------------------------------
--  Fetch and Add test.
--  Copyright (C) 2004  Anders Gidenstam
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
--  As a special exception, if other files instantiate generics from this
--  unit, or you link this unit with other files to produce an executable,
--  this unit does not by itself cause the resulting executable to be
--  covered by the GNU General Public License. This exception does not
--  however invalidate any other reasons why the executable file might be
--  covered by the GNU Public License.
-------------------------------------------------------------------------------
--                              -*- Mode: Ada -*-
--  Filename        : faa_test.adb
--  Description     : Test of synchronization primitives package.
--  Author          : Anders Gidenstam
--  Created On      : Tue Jul  9 14:07:11 2002
--  $Id: faa_test.adb,v 1.4 2005/09/23 15:21:49 anders Exp $
-------------------------------------------------------------------------------

with Primitives;
with Ada.Text_IO;
with Ada.Exceptions;

procedure FAA_Test is

   Count : aliased Primitives.Unsigned_32 := 0;
   pragma Atomic (Count);
   Count_CAS : aliased Primitives.Unsigned_32 := 0;
   pragma Atomic (Count_CAS);

   function CAS is
     new Primitives.Boolean_Compare_And_Swap_32 (Primitives.Unsigned_32);

   task type Counter;

   task body Counter is
   begin
      for I in 1 .. 10_000_000 loop
         Primitives.Fetch_And_Add (Target    => Count'Access,
                                   Increment => 1);
--           loop
--              declare
--                 use type Primitives.Unsigned_32;
--                 T : Primitives.Unsigned_32 := Count_CAS;
--              begin
--                 exit when CAS (Count_CAS'Access, T, T + 1);
--              end;
--           end loop;
      end loop;
      Ada.Text_IO.Put_Line ("Count: " &
                            Primitives.Unsigned_32'Image (Count) &
                            "  Count_CAS: " &
                            Primitives.Unsigned_32'Image (Count_CAS));
   exception
      when E : others =>
         Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (E));
   end Counter;

   type Counter_Access is access Counter;
   type Counter_Array is array (Positive range <>) of Counter_Access;

   Counters : Counter_Array (1 .. 10);
begin
   declare
      Test : aliased Primitives.Unsigned_32 := 0;
   begin
      Ada.Text_IO.Put_Line ("Test 1: 10 x FAA(Test'Access, 2)." &
                            "Expected outcome: 0, 2, 4, .. , 18.");
      for I in 1 .. 10 loop
         Ada.Text_IO.Put_Line
           ("FAA(Test'Access, 2):" &
            Primitives.Unsigned_32'Image
            (Primitives.Fetch_And_Add (Target    => Test'Access,
                                       Increment => 2)));
      end loop;
   end;

   Ada.Text_IO.Put_Line ("Test 2: 10 concurrent tasks count to " &
                         "10_000_000 each. Expected final outcome: " &
                         "100_000_000.");

   --  Start tasks;
   for I in Counters'Range loop
      Counters (I) := new Counter;
   end loop;
end FAA_Test;
