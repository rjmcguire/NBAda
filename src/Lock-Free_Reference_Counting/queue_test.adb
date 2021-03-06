-------------------------------------------------------------------------------
--  Lock-free Queue - Test for Michael and Scott's lock-free queue.
--
--  Copyright (C) 2004 - 2008  Anders Gidenstam
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
--                              -*- Mode: Ada -*-
--  Filename        : queue_test.adb
--  Description     : Example application for lock-free reference counting.
--  Author          : Anders Gidenstam
--  Created On      : Wed Apr 13 22:09:40 2005
--  $Id: queue_test.adb,v 1.4.2.1 2008/09/17 22:49:47 andersg Exp $
-------------------------------------------------------------------------------

pragma License (GPL);

with NBAda.Primitives;

with Ada.Text_IO;
with Ada.Exceptions;

with Ada.Real_Time;

with My_Queue;

procedure Queue_Test is

   use NBAda;

   use My_Queue;
   use My_Queue.Queues;

   ----------------------------------------------------------------------------
   --  Test application.
   ----------------------------------------------------------------------------

   No_Of_Elements : constant := 10_000;
   QUEUE_FIFO_PROPERTY_VIOLATION : exception;

   Output_File : Ada.Text_IO.File_Type renames
     Ada.Text_IO.Standard_Output;
--     Ada.Text_IO.Standard_Error;

   task type Producer is
      pragma Storage_Size (1 * 1024 * 1024);
   end Producer;

   task type Consumer is
      pragma Storage_Size (1 * 1024 * 1024);
   end Consumer;

   Queue                : aliased Queues.Queue_Type;

   Start                : aliased Primitives.Unsigned_32 := 0;
   pragma Atomic (Start);
   Enqueue_Count        : aliased Primitives.Unsigned_32 := 0;
   pragma Atomic (Enqueue_Count);
   Dequeue_Count        : aliased Primitives.Unsigned_32 := 0;
   pragma Atomic (Dequeue_Count);
   No_Producers_Running : aliased Primitives.Unsigned_32 := 0;
   pragma Atomic (No_Producers_Running);
   No_Consumers_Running : aliased Primitives.Unsigned_32 := 0;
   pragma Atomic (No_Consumers_Running);

   ----------------------------------------------------------------------------
   task body Producer is
      No_Enqueues : Primitives.Unsigned_32 := 0;
   begin
      PID.Register;
      Primitives.Fetch_And_Add_32 (No_Producers_Running'Access, 1);

      declare
         use type Primitives.Unsigned_32;
      begin
         while Start = 0 loop
            null;
         end loop;
      end;

      declare
         ID          : constant PID.Process_ID_Type := PID.Process_ID;
      begin
         for I in 1 .. No_Of_Elements loop
            Enqueue (Queue, Value_Type'(ID, I));
            No_Enqueues := Primitives.Unsigned_32'Succ (No_Enqueues);
         end loop;

      exception
         when E : others =>
            Ada.Text_IO.New_Line (Output_File);
            Ada.Text_IO.Put_Line (Output_File,
                                  "Producer (" &
                                  PID.Process_ID_Type'Image (ID) &
                                  "): raised " &
                                  Ada.Exceptions.Exception_Name (E) &
                                  " : " &
                                  Ada.Exceptions.Exception_Message (E));
            Ada.Text_IO.New_Line (Output_File);
      end;
      declare
         use type Primitives.Unsigned_32;
      begin
         Primitives.Fetch_And_Add_32 (Enqueue_Count'Access, No_Enqueues);
         Primitives.Fetch_And_Add_32 (No_Producers_Running'Access, -1);
      end;
      Ada.Text_IO.Put_Line (Output_File,
                            "Producer (?): exited.");

   exception
      when E : others =>
         Ada.Text_IO.New_Line (Output_File);
         Ada.Text_IO.Put_Line (Output_File,
                               "Producer (?): raised " &
                               Ada.Exceptions.Exception_Name (E) &
                               " : " &
                               Ada.Exceptions.Exception_Message (E));
         Ada.Text_IO.New_Line (Output_File);
   end Producer;

   ----------------------------------------------------------------------------
   task body Consumer is
      No_Dequeues : Primitives.Unsigned_32 := 0;
   begin
      PID.Register;
      Primitives.Fetch_And_Add_32 (No_Consumers_Running'Access, 1);

      declare
         ID   : constant PID.Process_ID_Type := PID.Process_ID;
         Last : array (PID.Process_ID_Type) of Integer := (others => 0);
         V    : Value_Type;
         Done : Boolean := False;
         pragma Volatile (Done); --  Strange GNAT GPL 2008 workaround.
      begin

         declare
            use type Primitives.Unsigned_32;
         begin
            while Start = 0 loop
               null;
            end loop;
         end;

         loop

            begin
               V           := Dequeue (Queue'Access);
               No_Dequeues := Primitives.Unsigned_32'Succ (No_Dequeues);

               Done := False;

               if V.Index <= Last (V.Creator) then
                  raise QUEUE_FIFO_PROPERTY_VIOLATION;
               end if;
               Last (V.Creator) := V.Index;

            exception
               when Queues.Queue_Empty =>
                  Ada.Text_IO.Put (".");
                  declare
                     use type Primitives.Unsigned_32;
                  begin
                     exit when Done and No_Producers_Running = 0;
                  end;
                  delay 0.0;

                  Done := True;
            end;
         end loop;

      exception
         when E : others =>
            Ada.Text_IO.New_Line (Output_File);
            Ada.Text_IO.Put_Line (Output_File,
                                  "Consumer (" &
                                  PID.Process_ID_Type'Image (ID) &
                                  "): raised " &
                                  Ada.Exceptions.Exception_Name (E) &
                                  " : " &
                                  Ada.Exceptions.Exception_Message (E));
            Ada.Text_IO.New_Line (Output_File);
      end;

      declare
         use type Primitives.Unsigned_32;
      begin
         Primitives.Fetch_And_Add_32 (Dequeue_Count'Access, No_Dequeues);
         Primitives.Fetch_And_Add_32 (No_Consumers_Running'Access, -1);
      end;

      Ada.Text_IO.Put_Line (Output_File,
                            "Consumer (?): exited.");
   exception
      when E : others =>
            Ada.Text_IO.New_Line (Output_File);
            Ada.Text_IO.Put_Line (Output_File,
                                  "Consumer (?): raised " &
                                  Ada.Exceptions.Exception_Name (E) &
                                  " : " &
                                  Ada.Exceptions.Exception_Message (E));
            Ada.Text_IO.New_Line (Output_File);
   end Consumer;

   use type Ada.Real_Time.Time;
   T1, T2 : Ada.Real_Time.Time;
begin
   PID.Register;

   Ada.Text_IO.Put ("Initializing: ");
   Init (Queue);
   Ada.Text_IO.Put_Line (" Queue ");

   Ada.Text_IO.Put_Line ("Testing with producer/consumer tasks.");
   declare
      use type Primitives.Unsigned_32;
      P0, P1, P2, P3, P4, P5, P6, P7, P8, P9, P10, P11, P12, P13, P14
        : Producer;
      C0, C1, C2, C3, C4, C5, C6, C7, C8, C9, C10, C11, C12, C13, C14
        : Consumer;
   begin
      delay 5.0;
      T1 := Ada.Real_Time.Clock;
      Primitives.Fetch_And_Add_32 (Start'Access, 1);
   end;
--     declare
--        C1 : Consumer;
--     begin
--        null;
--     end;
   T2 := Ada.Real_Time.Clock;

   delay 1.0;
   Ada.Text_IO.Put_Line ("Enqueue count: " &
                         Primitives.Unsigned_32'Image (Enqueue_Count));
   Ada.Text_IO.Put_Line ("Dequeue count: " &
                         Primitives.Unsigned_32'Image (Dequeue_Count));
   Ada.Text_IO.Put_Line ("Elapsed time:" &
                         Duration'Image (Ada.Real_Time.To_Duration (T2 - T1)));

   Ada.Text_IO.Put_Line ("Emptying queue.");
   delay 5.0;

   declare
      V : Value_Type;
   begin
      loop
         V := Dequeue (Queue'Access);
         Ada.Text_IO.Put_Line (Output_File,
                               "Dequeue() = (" &
                               PID.Process_ID_Type'Image (V.Creator) & ", " &
                               Integer'Image (V.Index) & ")");
         Primitives.Fetch_And_Add_32 (Dequeue_Count'Access, 1);
      end loop;
   exception
      when E : others =>
         Ada.Text_IO.New_Line (Output_File);
         Ada.Text_IO.Put_Line (Output_File,
                               "raised " &
                               Ada.Exceptions.Exception_Name (E) &
                               " : " &
                               Ada.Exceptions.Exception_Message (E));
         Ada.Text_IO.New_Line (Output_File);

         Ada.Text_IO.Put_Line ("Final enqueue count: " &
                               Primitives.Unsigned_32'Image (Enqueue_Count));
         Ada.Text_IO.Put_Line ("Final dequeue count: " &
                               Primitives.Unsigned_32'Image (Dequeue_Count));
         My_Queue.Queues.LFMR.Print_Statistics;
   end;
end Queue_Test;
